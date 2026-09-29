import Foundation

/// Just enough ASN.1/DER to pull the subject and validity out of the
/// certificates embedded in a `.mobileprovision`.
///
/// Doing it in-process matters here: a profile can carry half a dozen
/// certificates, and shelling out to `openssl x509` once per certificate per
/// profile turns a fast directory scan into hundreds of process spawns.
enum DER {
    struct Element {
        let tag: UInt8
        let content: ArraySlice<UInt8>
    }

    struct Parser {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var nextTag: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func readElement() -> Element? {
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            var header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, index + 2 + count <= bytes.count else { return nil }
                length = 0
                for i in 0..<count {
                    length = (length << 8) | Int(bytes[index + 2 + i])
                }
                header = 2 + count
            }
            let start = index + header
            guard start + length <= bytes.count else { return nil }
            index = start + length
            return Element(tag: tag, content: bytes[start..<(start + length)])
        }

        mutating func skip() { _ = readElement() }
    }

    // OID 2.5.4.3 (CN) and 2.5.4.11 (OU) — the only two we care about.
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidOrganizationalUnit: [UInt8] = [0x55, 0x04, 0x0B]

    static func certificateSummary(
        _ der: Data
    ) -> (commonName: String, teamID: String, notBefore: Date?, notAfter: Date?)? {
        var outer = Parser(der)
        guard let certificate = outer.readElement(), certificate.tag == 0x30 else { return nil }
        var tbs = Parser(Data(certificate.content))
        guard let tbsElement = tbs.readElement(), tbsElement.tag == 0x30 else { return nil }

        var inner = Parser(Data(tbsElement.content))
        // [0] EXPLICIT version is optional
        if let tag = inner.nextTag, tag == 0xA0 { _ = inner.readElement() }
        inner.skip()   // serialNumber INTEGER
        inner.skip()   // signature AlgorithmIdentifier SEQUENCE
        inner.skip()   // issuer Name SEQUENCE
        guard let validity = inner.readElement(), validity.tag == 0x30 else { return nil }
        guard let subject = inner.readElement(), subject.tag == 0x30 else { return nil }

        var times: [Date] = []
        var validityParser = Parser(Data(validity.content))
        while let element = validityParser.readElement() {
            if let date = parseTime(String(decoding: element.content, as: UTF8.self)) {
                times.append(date)
            }
        }

        var commonName = ""
        var teamID = ""
        var subjectParser = Parser(Data(subject.content))
        while let rdn = subjectParser.readElement() {                    // SET
            var rdnParser = Parser(Data(rdn.content))
            while let atv = rdnParser.readElement() {                    // SEQUENCE
                var atvParser = Parser(Data(atv.content))
                guard let oid = atvParser.readElement(),
                      let value = atvParser.readElement() else { continue }
                let oidBytes = Array(oid.content)
                let text = String(decoding: value.content, as: UTF8.self)
                if oidBytes == oidCommonName { commonName = text }
                if oidBytes == oidOrganizationalUnit { teamID = text }
            }
        }

        return (commonName, teamID, times.first, times.last)
    }

    /// X.509 `Time`: UTCTime `YYMMDDHHMMSSZ` or GeneralizedTime `YYYYMMDDHHMMSSZ`.
    /// Parsed by hand into UTC — locale-independent and immune to the current
    /// time zone, which `DateFormatter` is not.
    static func parseTime(_ raw: String) -> Date? {
        var digits = Array(raw.prefix(while: \.isNumber))
        guard digits.count >= 10 else { return nil }

        var year: Int
        if digits.count >= 14 {                    // GeneralizedTime
            year = Int(String(digits[0...3])) ?? 0
            digits.removeFirst(4)
        } else {                                   // UTCTime
            let two = Int(String(digits[0...1])) ?? 0
            year = two < 50 ? 2000 + two : 1900 + two
            digits.removeFirst(2)
        }

        func take(_ n: Int) -> Int {
            let value = Int(String(digits.prefix(n))) ?? 0
            digits.removeFirst(min(n, digits.count))
            return value
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: take(2), day: take(2),
            hour: take(2), minute: take(2), second: take(2)
        ))
    }
}
