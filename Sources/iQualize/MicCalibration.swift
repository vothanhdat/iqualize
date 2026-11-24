import Foundation

/// A measurement microphone's calibration file: its deviation from flat at each frequency,
/// subtracted from a measurement so the mic's own coloration isn't "corrected" into the EQ.
///
/// Reads the plain-text format miniDSP (UMIK-1/2), Dayton, and REW use: an optional header
/// such as `"Sens Factor =-1.378dB, SERNO: 7101234"`, then one `frequency dB [phase]` row
/// per line, separated by tabs, spaces, or commas. Comments and anything else unparsable
/// are skipped.
struct MicCalibration: Equatable, Sendable {
    var name: String
    /// The "Sens Factor" from the header, if present. Informational only: it shifts the
    /// absolute level, which the fitter normalizes away anyway.
    var sensitivityDB: Double?
    /// Ascending frequencies (Hz) and the mic's deviation (dB) at each.
    var frequencies: [Double]
    var deviationsDB: [Double]

    enum ParseError: Error, LocalizedError {
        case tooFewPoints(Int)

        var errorDescription: String? {
            switch self {
            case .tooFewPoints(let n):
                "This doesn't look like a microphone calibration file — found \(n) frequency/dB "
                    + "row\(n == 1 ? "" : "s"), need at least 2."
            }
        }
    }

    static func parse(_ text: String, name: String) throws -> MicCalibration {
        var sensitivity: Double?
        var points: [(Double, Double)] = []
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;"))

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if sensitivity == nil, let range = line.range(of: "Sens Factor", options: .caseInsensitive) {
                sensitivity = firstNumber(in: line[range.upperBound...])
                continue
            }
            if line.hasPrefix("*") || line.hasPrefix("#") || line.hasPrefix("\"") || line.hasPrefix("//") {
                continue
            }
            let fields = line.components(separatedBy: separators).filter { !$0.isEmpty }
            guard fields.count >= 2,
                  let f = Double(fields[0]), let db = Double(fields[1]),
                  f.isFinite, db.isFinite, f > 0 else { continue }
            points.append((f, db))
        }

        points.sort { $0.0 < $1.0 }
        // Drop repeated frequencies, keeping the first.
        var deduped: [(Double, Double)] = []
        for p in points where deduped.last?.0 != p.0 { deduped.append(p) }
        guard deduped.count >= 2 else { throw ParseError.tooFewPoints(deduped.count) }

        return MicCalibration(name: name, sensitivityDB: sensitivity,
                              frequencies: deduped.map(\.0), deviationsDB: deduped.map(\.1))
    }

    /// The mic's deviation at `hz`, interpolated in log-frequency and held at the ends.
    func dB(at hz: Double) -> Double {
        FrequencyCurve(frequencies: frequencies, dB: deviationsDB).value(at: hz)
    }

    /// `curve` with the mic's deviation removed.
    func applied(to curve: FrequencyCurve) -> FrequencyCurve {
        curve.adding(FrequencyCurve(frequencies: frequencies, dB: deviationsDB), scale: -1)
    }

    private static func firstNumber(in text: Substring) -> Double? {
        let scanner = Scanner(string: String(text))
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \t=:")
        return scanner.scanDouble()
    }
}
