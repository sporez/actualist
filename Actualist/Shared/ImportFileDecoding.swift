import Foundation

/// Turns a file's bytes into the text Actual's CSV import parses (pinned
/// v26.11.0 `parse-file.ts`): `decodeCsvBytes` (the WHATWG `TextDecoder`
/// for the chosen label, or `auto`), then the skip-lines step of `parseCSV`.
/// The `file-import` oracle replays both.
enum ImportFileDecoding {
    enum DecodingError: Error, Equatable {
        /// `new TextDecoder(label)` throws for a label it does not know.
        /// Actualist also refuses the WHATWG encodings outside the ones
        /// Actual's import offers plus ISO-8859-15 (for example the
        /// multi-byte Asian ones); only a preference set outside Actual's
        /// import can name one.
        case unsupportedEncoding(String)
        /// `parseCSV`: "Cannot skip more lines than exist in the file".
        case skipsTooManyLines
    }

    private enum Encoding {
        case utf8, utf16LE, utf16BE, singleByte([UInt16])
    }

    /// `decodeCsvBytes(bytes, encoding)`. The UTF-8 and UTF-16 decoders drop
    /// one leading BOM, as `TextDecoder` does; single-byte ones keep every
    /// byte.
    static func decode(_ bytes: [UInt8], encoding label: String) throws -> [Unicode.Scalar] {
        let encoding: Encoding
        if label == "auto" {
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
                encoding = .utf16LE
            } else if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
                encoding = .utf16BE
            } else {
                encoding = .utf8
            }
        } else {
            guard let resolved = resolve(label) else {
                throw DecodingError.unsupportedEncoding(label)
            }
            encoding = resolved
        }
        var scalars: [Unicode.Scalar]
        switch encoding {
        case .utf8:
            // Swift's repair replaces ill-formed UTF-8 with U+FFFD per maximal
            // subpart, as the WHATWG decoder does.
            scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        case .utf16LE:
            scalars = decodeUTF16(bytes, littleEndian: true)
        case .utf16BE:
            scalars = decodeUTF16(bytes, littleEndian: false)
        case .singleByte(let high):
            return bytes.map { byte in
                byte < 0x80 ? Unicode.Scalar(byte) : Unicode.Scalar(UInt32(high[Int(byte) - 0x80]))!
            }
        }
        if scalars.first == "\u{FEFF}" {
            scalars.removeFirst()
        }
        return scalars
    }

    /// `parseCSV`'s skip step: split on `\r?\n`, drop lines from each end,
    /// rejoin with `\r\n`. Negative counts are 0. A trailing newline leaves an
    /// empty last line, which counts.
    static func skipLines(_ scalars: [Unicode.Scalar], start: Int, end: Int) throws -> [Unicode.Scalar] {
        let skipStart = max(0, start)
        let skipEnd = max(0, end)
        guard skipStart > 0 || skipEnd > 0 else { return scalars }
        var lines: [ArraySlice<Unicode.Scalar>] = []
        var lineStart = 0
        for (index, scalar) in scalars.enumerated() where scalar == "\n" {
            let lineEnd = index > lineStart && scalars[index - 1] == "\r" ? index - 1 : index
            lines.append(scalars[lineStart..<lineEnd])
            lineStart = index + 1
        }
        lines.append(scalars[lineStart...])
        guard skipStart < lines.count, skipEnd < lines.count - skipStart else {
            throw DecodingError.skipsTooManyLines
        }
        var result: [Unicode.Scalar] = []
        for (offset, line) in lines[skipStart..<(lines.count - skipEnd)].enumerated() {
            if offset > 0 { result.append(contentsOf: ["\r", "\n"]) }
            result.append(contentsOf: line)
        }
        return result
    }

    /// WHATWG "get an encoding" for the encodings Actual's import offers:
    /// ASCII whitespace trimmed, ASCII case ignored.
    private static func resolve(_ label: String) -> Encoding? {
        let asciiWhitespace: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", "\r", " "]
        let trimmed = label.unicodeScalars
            .drop(while: asciiWhitespace.contains)
            .reversed().drop(while: asciiWhitespace.contains).reversed()
        let key = JavaScriptText.string(trimmed.map(JavaScriptText.asciiLowercased))
        switch key {
        case "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8":
            return .utf8
        case "csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le":
            return .utf16LE
        case "unicodefffe", "utf-16be":
            return .utf16BE
        case "ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100",
             "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii",
             "windows-1252", "x-cp1252":
            return .singleByte(windows1252)
        case "cp1250", "windows-1250", "x-cp1250":
            return .singleByte(windows1250)
        case "csisolatin2", "iso-8859-2", "iso-ir-101", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987",
             "l2", "latin2":
            return .singleByte(iso8859_2)
        case "csisolatin9", "iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "l9":
            return .singleByte(iso8859_15)
        default:
            return nil
        }
    }

    /// The WHATWG UTF-16 decoder: an unpaired surrogate becomes U+FFFD and
    /// the following unit is read again; input ending mid-unit or after a
    /// lead surrogate yields one U+FFFD.
    private static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(bytes.count / 2)
        var leadByte: UInt8?
        var leadSurrogate: UInt32?
        for byte in bytes {
            guard let first = leadByte else {
                leadByte = byte
                continue
            }
            leadByte = nil
            let unit = littleEndian ? UInt32(first) | UInt32(byte) << 8 : UInt32(first) << 8 | UInt32(byte)
            if let lead = leadSurrogate {
                leadSurrogate = nil
                if (0xDC00...0xDFFF).contains(unit) {
                    scalars.append(Unicode.Scalar(0x10000 + ((lead - 0xD800) << 10) + (unit - 0xDC00))!)
                    continue
                }
                scalars.append("\u{FFFD}")
            }
            if (0xD800...0xDBFF).contains(unit) {
                leadSurrogate = unit
            } else if (0xDC00...0xDFFF).contains(unit) {
                scalars.append("\u{FFFD}")
            } else {
                scalars.append(Unicode.Scalar(unit)!)
            }
        }
        if leadByte != nil || leadSurrogate != nil {
            scalars.append("\u{FFFD}")
        }
        return scalars
    }

    // WHATWG index tables for bytes 0x80-0xFF, generated from `TextDecoder`
    // and pinned byte by byte by the `decodeCsvBytes` oracle cases.
    private static let windows1252: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
        0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
        0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
        0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
        0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
        0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
        0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
    ]

    private static let windows1250: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0083, 0x201E, 0x2026, 0x2020, 0x2021,
        0x0088, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x0098, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
        0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7,
        0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
        0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
        0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
        0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7,
        0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
        0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7,
        0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
        0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7,
        0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
        0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7,
        0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
    ]

    private static let iso8859_15: [UInt16] = [
        0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085, 0x0086, 0x0087,
        0x0088, 0x0089, 0x008A, 0x008B, 0x008C, 0x008D, 0x008E, 0x008F,
        0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095, 0x0096, 0x0097,
        0x0098, 0x0099, 0x009A, 0x009B, 0x009C, 0x009D, 0x009E, 0x009F,
        0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x20AC, 0x00A5, 0x0160, 0x00A7,
        0x0161, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x017D, 0x00B5, 0x00B6, 0x00B7,
        0x017E, 0x00B9, 0x00BA, 0x00BB, 0x0152, 0x0153, 0x0178, 0x00BF,
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
        0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
        0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
        0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
        0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
    ]

    private static let iso8859_2: [UInt16] = [
        0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085, 0x0086, 0x0087,
        0x0088, 0x0089, 0x008A, 0x008B, 0x008C, 0x008D, 0x008E, 0x008F,
        0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095, 0x0096, 0x0097,
        0x0098, 0x0099, 0x009A, 0x009B, 0x009C, 0x009D, 0x009E, 0x009F,
        0x00A0, 0x0104, 0x02D8, 0x0141, 0x00A4, 0x013D, 0x015A, 0x00A7,
        0x00A8, 0x0160, 0x015E, 0x0164, 0x0179, 0x00AD, 0x017D, 0x017B,
        0x00B0, 0x0105, 0x02DB, 0x0142, 0x00B4, 0x013E, 0x015B, 0x02C7,
        0x00B8, 0x0161, 0x015F, 0x0165, 0x017A, 0x02DD, 0x017E, 0x017C,
        0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7,
        0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
        0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7,
        0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
        0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7,
        0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
        0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7,
        0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
    ]
}
