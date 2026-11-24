import Accelerate
import AVFAudio
import Foundation

/// Turns a recorded sweep into the room's magnitude response:
///
///     recording ÷ sweep (regularized spectral division) → impulse response
///     → window around the direct sound → FFT → dB on `FrequencyCurve.standardGrid`
///
/// Dividing by the sweep's own spectrum is the frequency-domain form of Farina's inverse
/// filter: the linear response lands at the system's latency, while harmonic distortion
/// lands before it (wrapped to the end of the buffer) and falls outside the window.
enum ImpulseResponseAnalysis {
    /// Window kept before the impulse response's peak. The analysis's own band-limiting is
    /// zero-phase, so its low-frequency ringing is split evenly either side of the peak, and
    /// cutting the early half off would pull the bass down. A 6 s sweep puts the 2nd
    /// harmonic's distortion products ~0.5 s before the peak, well outside this.
    static let preWindowSeconds = 0.1
    /// Window kept after the peak. 500 ms resolves room modes down to 20 Hz; the
    /// fractional-octave smoothing afterwards evens out the reflections it also includes.
    static let postWindowSeconds = 0.5

    // MARK: - Levels

    static func peakLevelDBFS(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return -.infinity }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    static func rmsLevelDBFS(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return -.infinity }
        var rms: Float = 0
        vDSP_rmsqv(x, 1, &rms, vDSP_Length(x.count))
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    // MARK: - Resampling

    /// Band-limited sample-rate conversion (AVAudioConverter, mastering quality). Used when
    /// the microphone runs at a different rate than the output the sweep was played on.
    static func resample(_ x: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate != outputRate, inputRate > 0, outputRate > 0, !x.isEmpty,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                                           channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count))
        else { return x }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: x.count)
        }

        let expected = Int((Double(x.count) * outputRate / inputRate).rounded())
        let chunk = AVAudioFrameCount(max(4096, expected + 4096))
        let feeder = ConverterFeeder(buffer: input)
        var result: [Float] = []
        result.reserveCapacity(expected + 4096)
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                feeder.next(inputStatus)
            }
            if output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0],
                                                              count: Int(output.frameLength)))
            }
            if status != .haveData { break }
        }
        return result.isEmpty ? x : result
    }

    /// Hands the converter its single input buffer once, then signals end of stream.
    private final class ConverterFeeder: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var delivered = false
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
    }

    // MARK: - Deconvolution

    /// The impulse response of whatever the sweep passed through, by regularized spectral
    /// division. Outside the sweep's band the regularization drives the response to zero
    /// rather than amplifying noise. Index 0 is zero delay; the linear response's peak sits
    /// at the recording's latency.
    static func impulseResponse(recording: [Float], sweep: [Float], parameters p: SweepParameters) -> [Float] {
        guard !recording.isEmpty, !sweep.isEmpty else { return [] }
        let log2n = Int(ceil(log2(Double(recording.count + sweep.count))))
        guard let fft = RealFFT(log2n: log2n) else { return [] }
        let n = fft.n
        let x = fft.forward(sweep)
        let y = fft.forward(recording)

        let binHz = p.sampleRate / Double(n)
        var maxPower: Float = 0
        for k in 1..<(n / 2) {
            maxPower = max(maxPower, x.re[k] * x.re[k] + x.im[k] * x.im[k])
        }
        let inBandEpsilon = maxPower * 1e-6
        let outOfBandEpsilon = maxPower * 10

        var hRe = [Float](repeating: 0, count: n / 2)
        var hIm = [Float](repeating: 0, count: n / 2)
        // Bin 0 (DC) and the packed Nyquist value stay 0: both lie outside every sweep.
        for k in 1..<(n / 2) {
            let f = Double(k) * binHz
            let taper = Float(bandEdgeTaper(f, parameters: p))
            guard taper > 0 else { continue }
            let eps = (f >= p.startHz && f <= p.endHz) ? inBandEpsilon : outOfBandEpsilon
            let xr = x.re[k], xi = x.im[k], yr = y.re[k], yi = y.im[k]
            let denom = (xr * xr + xi * xi + eps) / taper
            // Y · conj(X) / (|X|² + ε), faded out at the sweep's band edges
            hRe[k] = (yr * xr + yi * xi) / denom
            hIm[k] = (yi * xr - yr * xi) / denom
        }
        return fft.inverse(re: hRe, im: hIm)
    }

    /// Raised-cosine fade over the sweep's lowest ~0.85 octave and top 5%. A hard edge
    /// would ring for longer than the analysis window, and cutting that ringing off
    /// pulls the response near the edge down. The standard sweep starts at 10 Hz, so the
    /// fade is finished before the 20 Hz analysis band begins.
    static func bandEdgeTaper(_ f: Double, parameters p: SweepParameters) -> Double {
        let lowEnd = p.startHz * 1.8
        let highStart = p.endHz * 0.95
        if f <= p.startHz || f >= p.endHz { return 0 }
        if f < lowEnd { return 0.5 - 0.5 * cos(Double.pi * (f - p.startHz) / (lowEnd - p.startHz)) }
        if f > highStart { return 0.5 + 0.5 * cos(Double.pi * (f - highStart) / (p.endHz - highStart)) }
        return 1
    }

    // MARK: - Magnitude response

    /// The room's magnitude response for one recorded sweep, in dB on
    /// `FrequencyCurve.standardGrid`, before smoothing. The absolute level is arbitrary
    /// (it depends on the mic's gain and the system volume); the fitter aligns it.
    static func magnitudeResponse(recording: [Float], recordingRate: Double,
                                  sweep p: SweepParameters) -> FrequencyCurve {
        let rec = recordingRate == p.sampleRate
            ? recording
            : resample(recording, from: recordingRate, to: p.sampleRate)
        let ir = impulseResponse(recording: rec, sweep: SweepSignal.sweep(p), parameters: p)
        return magnitudeResponse(impulseResponse: ir, sampleRate: p.sampleRate)
    }

    /// Windows `ir` around its peak and samples its spectrum onto the standard grid. Each
    /// grid point is the mean power of the FFT bins within ±1/96 octave of it (or the
    /// interpolated bin power where that span holds no bin), so the curve is a fair
    /// 1/48-octave reading at every frequency rather than a single noisy bin.
    static func magnitudeResponse(impulseResponse ir: [Float], sampleRate: Double) -> FrequencyCurve {
        let grid = FrequencyCurve.standardGrid
        guard !ir.isEmpty else { return FrequencyCurve(frequencies: grid, dB: grid.map { _ in -120 }) }

        var peakIndex: vDSP_Length = 0
        var peak: Float = 0
        vDSP_maxmgvi(ir, 1, &peak, &peakIndex, vDSP_Length(ir.count))

        let pre = max(1, Int(preWindowSeconds * sampleRate))
        let post = max(2, Int(postWindowSeconds * sampleRate))
        let taperStart = Int(Double(post) * 0.6)
        let length = pre + post
        var windowed = [Float](repeating: 0, count: length)
        let count = ir.count
        for j in 0..<length {
            // Indices before 0 wrap to the end — that's where a zero-latency peak's
            // pre-ringing lives in a circular deconvolution.
            let idx = ((Int(peakIndex) - pre + j) % count + count) % count
            let w: Double
            if j < pre {
                // Flat for the half nearest the peak, half-Hann fade before that.
                let fade = pre / 2
                w = j < fade ? 0.5 - 0.5 * cos(Double.pi * Double(j) / Double(fade)) : 1
            } else {
                let k = j - pre
                w = k < taperStart
                    ? 1
                    : 0.5 + 0.5 * cos(Double.pi * Double(k - taperStart) / Double(post - taperStart))
            }
            windowed[j] = ir[idx] * Float(w)
        }

        let log2n = max(16, Int(ceil(log2(Double(length)))))
        guard let fft = RealFFT(log2n: log2n) else { return FrequencyCurve(frequencies: grid, dB: grid.map { _ in -120 }) }
        let spectrum = fft.forward(windowed)
        let bins = fft.n / 2
        var power = [Double](repeating: 0, count: bins)
        for k in 0..<bins {
            power[k] = Double(spectrum.re[k] * spectrum.re[k] + spectrum.im[k] * spectrum.im[k])
        }
        power[0] = Double(spectrum.re[0] * spectrum.re[0])   // packed DC (imag slot is Nyquist)
        let binHz = sampleRate / Double(fft.n)

        let halfStep = pow(2.0, 0.5 / FrequencyCurve.pointsPerOctave)
        let dB = grid.map { f -> Double in
            let lo = Int(ceil(f / halfStep / binHz))
            let hi = min(bins - 1, Int(floor(f * halfStep / binHz)))
            var p: Double
            if hi >= lo, lo >= 0 {
                var sum = 0.0
                for k in lo...hi { sum += power[k] }
                p = sum / Double(hi - lo + 1)
            } else {
                let exact = f / binHz
                let k0 = min(bins - 2, max(0, Int(floor(exact))))
                let t = exact - Double(k0)
                p = power[k0] * (1 - t) + power[k0 + 1] * t
            }
            return 10 * log10(max(p, 1e-12))
        }
        return FrequencyCurve(frequencies: grid, dB: dB)
    }

    // MARK: - Smoothing and averaging

    /// Fractional-octave smoothing: each point becomes the mean power of the points within
    /// ±fraction/2 octave of it. `fraction` 1/6 is the usual choice for room EQ: it keeps
    /// room modes but evens out comb filtering no EQ can fix.
    static func smoothed(_ curve: FrequencyCurve, fraction: Double) -> FrequencyCurve {
        let n = curve.dB.count
        guard n > 2, fraction > 0 else { return curve }
        let power = curve.dB.map { pow(10, $0 / 10) }
        let halfWidth = pow(2.0, fraction / 2)
        var out = [Double](repeating: 0, count: n)
        var lo = 0, hi = 0
        var sum = 0.0
        // Sliding window over the (increasing) frequencies.
        for i in 0..<n {
            let f = curve.frequencies[i]
            while hi < n && curve.frequencies[hi] <= f * halfWidth { sum += power[hi]; hi += 1 }
            while lo < hi && curve.frequencies[lo] < f / halfWidth { sum -= power[lo]; lo += 1 }
            out[i] = 10 * log10(max(sum / Double(hi - lo), 1e-12))
        }
        return FrequencyCurve(frequencies: curve.frequencies, dB: out)
    }

    /// Mean power of several measurements (e.g. mic positions around the seat), on the first
    /// curve's frequencies. Power averaging keeps a null at one position from dragging the
    /// result down the way a dB average would.
    static func powerAverage(_ curves: [FrequencyCurve]) -> FrequencyCurve? {
        guard let first = curves.first else { return nil }
        guard curves.count > 1 else { return first }
        var sum = [Double](repeating: 0, count: first.frequencies.count)
        for curve in curves {
            let values = curve.frequencies == first.frequencies
                ? curve.dB
                : first.frequencies.map(curve.value(at:))
            for i in sum.indices { sum[i] += pow(10, values[i] / 10) }
        }
        let n = Double(curves.count)
        return FrequencyCurve(frequencies: first.frequencies, dB: sum.map { 10 * log10(max($0 / n, 1e-12)) })
    }
}

// MARK: - Real FFT

/// A power-of-two real FFT (vDSP split-complex, as in `SpectrumAnalyzer`), scaled so
/// `forward` returns the true DFT and `inverse` exactly undoes it. Spectra are packed as
/// vDSP packs them: element 0 holds DC in `re` and Nyquist in `im`.
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init?(log2n: Int) {
        guard log2n >= 2, log2n <= 24,
              let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        self.log2n = vDSP_Length(log2n)
        self.n = 1 << log2n
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        var padded = [Float](repeating: 0, count: n)
        let copied = min(x.count, n)
        padded.withUnsafeMutableBufferPointer { dst in
            x.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: copied)
            }
        }
        var re = [Float](repeating: 0, count: n / 2)
        var im = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBufferPointer { pp in
                    pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP's forward real FFT returns twice the DFT.
                var half: Float = 0.5
                vDSP_vsmul(rp.baseAddress!, 1, &half, rp.baseAddress!, 1, vDSP_Length(n / 2))
                vDSP_vsmul(ip.baseAddress!, 1, &half, ip.baseAddress!, 1, vDSP_Length(n / 2))
            }
        }
        return (re, im)
    }

    func inverse(re: [Float], im: [Float]) -> [Float] {
        precondition(re.count == n / 2 && im.count == n / 2)
        var re = re, im = im
        var out = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2))
                    }
                }
            }
        }
        // The inverse of a true DFT comes back n times too large.
        var scale = 1 / Float(n)
        out.withUnsafeMutableBufferPointer { op in
            vDSP_vsmul(op.baseAddress!, 1, &scale, op.baseAddress!, 1, vDSP_Length(n))
        }
        return out
    }
}
