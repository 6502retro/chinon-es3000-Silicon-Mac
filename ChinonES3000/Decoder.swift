//  Decoder.swift — Chinon ES-3000 .DCT and thumbnail decoder.
//
//  Swift port of chinon_decode.py from github.com/lustrinomatt/chinon-es3000-windows (MIT).
//  Format: optional 384-byte "Cdcx" header, a 128-byte info block, then three planes
//  (Y, Cr, Cb) of fixed-size DCT blocks whose bit fields are read LSB-first.
//  Foundation only, so it also builds and can be tested outside macOS.

import Foundation

/// A decoded picture: 8-bit RGB, row-major, 3 bytes per pixel.
struct RGBImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

enum Resolution: Int, CaseIterable, Identifiable {
    case superfine = 0, fine = 1, normal = 2
    var id: Int { rawValue }
    var code: String { ["SF", "F", "N"][rawValue] }
    var name: String { ["Superfine", "Fine", "Normal"][rawValue] }
    /// Bytes the camera sends for a full picture (whole 1 KB packets).
    var transferSize: Int { [194_560, 97_280, 24_576][rawValue] }
}

enum DecodeError: LocalizedError {
    case badParams, unknownResolution(Int), tooShort
    var errorDescription: String? {
        switch self {
        case .badParams: return "The decoder parameters are missing or damaged."
        case .unknownResolution(let r): return "Unknown picture resolution code \(r)."
        case .tooShort: return "The picture data is too short."
        }
    }
}

// MARK: - Parameters (chinon_params.json)

struct PlaneParams {
    struct Field { let pos: Int; let len: Int; let row: Int; let col: Int; let q: Double }
    let dcLen: Int
    let dcSigned: Bool
    let a0: Double, a1: Double
    let fields: [Field]

    init(_ d: [String: Any]) throws {
        guard let dcL = d["dcL"] as? Int, let A = d["A"] as? [Double], A.count == 2,
              let lay = d["lay"] as? [[Any]], let q = d["q"] as? [Double], lay.count == q.count
        else { throw DecodeError.badParams }
        dcLen = dcL
        dcSigned = (d["dcSigned"] as? Bool) ?? false
        a0 = A[0]; a1 = A[1]
        fields = try zip(lay, q).map { entry, qv in
            guard entry.count == 3, let p = entry[0] as? Int, let l = entry[1] as? Int,
                  let rc = entry[2] as? [Int], rc.count == 2 else { throw DecodeError.badParams }
            return Field(pos: p, len: l, row: rc[0], col: rc[1], q: qv)
        }
    }
}

struct ModeParams {
    let width: Int, height: Int, yBytes: Int, cBytes: Int
    let y: PlaneParams, cr: PlaneParams, cb: PlaneParams
}

final class ChinonDecoder {
    let modes: [Int: ModeParams]
    /// Learned 5×5 post-filter: 3 rows (Y, Cb, Cr) of 25 taps + bias.
    let post: [[Double]]?

    init(paramsData: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: paramsData) as? [String: Any]
        else { throw DecodeError.badParams }
        var m: [Int: ModeParams] = [:]
        for r in Resolution.allCases {
            guard let d = root[r.code] as? [String: Any],
                  let w = d["W"] as? Int, let h = d["H"] as? Int,
                  let yb = d["ybytes"] as? Int, let cb = d["cbytes"] as? Int,
                  let y = d["y"] as? [String: Any], let cr = d["cr"] as? [String: Any],
                  let cbp = d["cb"] as? [String: Any] else { throw DecodeError.badParams }
            m[r.rawValue] = ModeParams(width: w, height: h, yBytes: yb, cBytes: cb,
                                       y: try PlaneParams(y), cr: try PlaneParams(cr), cb: try PlaneParams(cbp))
        }
        modes = m
        if let p = root["post"] as? [[Double]], p.count == 3, p.allSatisfy({ $0.count == 26 }) {
            post = p
        } else {
            post = nil
        }
    }

    // MARK: Bit fields

    /// Reads `len` bits starting at bit `pos` (LSB-first) of a block starting at `base`.
    /// Bits beyond `limit` bits of the block read as nothing, like the numpy slice in the original.
    @inline(__always)
    private static func field(_ b: UnsafeBufferPointer<UInt8>, base: Int, pos: Int, len: Int,
                              limit: Int, signed: Bool) -> Int {
        let n = max(0, min(len, limit - pos))
        var v = 0
        for i in 0..<n {
            let bit = pos + i
            if (b[base + (bit >> 3)] >> UInt8(bit & 7)) & 1 == 1 { v |= 1 << i }
        }
        if signed && len > 0 && (v >> (len - 1)) & 1 == 1 { v -= 1 << len }
        return v
    }

    private static var idctCache: [Int: [Double]] = [:]
    private static let idctLock = NSLock()

    /// Orthonormal DCT-II basis: M[k][x] = cos(pi(2x+1)k/2n)·sqrt(2/n), row 0 divided by sqrt 2.
    private static func idctMatrix(_ n: Int) -> [Double] {
        idctLock.lock(); defer { idctLock.unlock() }
        if let m = idctCache[n] { return m }
        var m = [Double](repeating: 0, count: n * n)
        for k in 0..<n {
            for x in 0..<n {
                var v = cos(Double.pi * Double(2 * x + 1) * Double(k) / Double(2 * n)) * (2.0 / Double(n)).squareRoot()
                if k == 0 { v /= 2.0.squareRoot() }
                m[k * n + x] = v
            }
        }
        idctCache[n] = m
        return m
    }

    /// Decodes one plane of `count` blocks (bh rows × bw columns each) arranged gh × gw.
    private static func plane(_ buf: UnsafeBufferPointer<UInt8>, offset: Int, count: Int, blockBytes: Int,
                              p: PlaneParams, bh: Int, bw: Int, gh: Int, gw: Int) -> [Double] {
        let W = gw * bw, H = gh * bh
        var out = [Double](repeating: 0, count: W * H)
        let Mr = idctMatrix(bh), Mc = idctMatrix(bw)
        let limit = blockBytes * 8
        var C = [Double](repeating: 0, count: bh * bw)
        var T = [Double](repeating: 0, count: bh * bw)   // T = Mrᵀ·C
        for n in 0..<count {
            let base = offset + n * blockBytes
            for i in 0..<C.count { C[i] = 0 }
            let dc = field(buf, base: base, pos: 0, len: p.dcLen, limit: limit, signed: p.dcSigned)
            C[0] = Double(dc) * p.a0 + p.a1
            for f in p.fields {
                C[f.row * bw + f.col] = Double(field(buf, base: base, pos: f.pos, len: f.len, limit: limit, signed: true)) * f.q
            }
            // blk[i][j] = Σr Σc Mr[r][i] · C[r][c] · Mc[c][j]
            for i in 0..<bh {
                for c in 0..<bw {
                    var s = 0.0
                    for r in 0..<bh { s += Mr[r * bh + i] * C[r * bw + c] }
                    T[i * bw + c] = s
                }
            }
            let gy = n / gw, gx = n % gw
            for i in 0..<bh {
                let row = (gy * bh + i) * W + gx * bw
                for j in 0..<bw {
                    var s = 0.0
                    for c in 0..<bw { s += T[i * bw + c] * Mc[c * bw + j] }
                    out[row + j] = s
                }
            }
        }
        return out
    }

    // MARK: Full picture

    /// Decodes a .DCT file (with "Cdcx" header) or raw camera image data.
    func decode(_ data: Data) throws -> (RGBImage, Resolution) {
        var bytes = [UInt8](data)
        let res: Int
        if bytes.count >= 384, bytes[0] == 0x43, bytes[1] == 0x64, bytes[2] == 0x63, bytes[3] == 0x78 { // "Cdcx"
            res = Int(bytes[12])
            bytes.removeFirst(384)
        } else {
            guard bytes.count > 4 else { throw DecodeError.tooShort }
            res = Int(bytes[4])
        }
        guard let P = modes[res], let resolution = Resolution(rawValue: res) else {
            throw DecodeError.unknownResolution(res)
        }
        let W = P.width, H = P.height
        let ny = (W / 16) * (H / 8), nc = (W / 16) * (H / 16)
        let needed = 128 + ny * P.yBytes + 2 * nc * P.cBytes
        guard bytes.count >= needed / 2 else { throw DecodeError.tooShort }
        if bytes.count < needed { bytes += [UInt8](repeating: 0, count: needed - bytes.count) }

        var Y = [Double](), Cr = [Double](), Cb = [Double]()
        bytes.withUnsafeBufferPointer { b in
            var o = 128
            Y = Self.plane(b, offset: o, count: ny, blockBytes: P.yBytes, p: P.y, bh: 8, bw: 16, gh: H / 8, gw: W / 16)
            o += ny * P.yBytes
            Cr = Self.plane(b, offset: o, count: nc, blockBytes: P.cBytes, p: P.cr, bh: 8, bw: 8, gh: H / 16, gw: W / 16)
            o += nc * P.cBytes
            Cb = Self.plane(b, offset: o, count: nc, blockBytes: P.cBytes, p: P.cb, bh: 8, bw: 8, gh: H / 16, gw: W / 16)
        }

        let cw = W / 2, ch = H / 2
        if let post = post {
            let cbUp = Self.resizeBilinear(Cb, w: cw, h: ch, outW: W, outH: H)
            let crUp = Self.resizeBilinear(Cr, w: cw, h: ch, outW: W, outH: H)
            Y = Self.filter5x5(Y, w: W, h: H, weights: post[0])
            Cb = Self.filter5x5(cbUp, w: W, h: H, weights: post[1])
            Cr = Self.filter5x5(crUp, w: W, h: H, weights: post[2])
        } else {
            Cr = Self.repeat2x(Cr, w: cw, h: ch)
            Cb = Self.repeat2x(Cb, w: cw, h: ch)
        }
        return (Self.toRGB(Y: Y, Cb: Cb, Cr: Cr, w: W, h: H), resolution)
    }

    // MARK: Thumbnail (camera command 56)

    /// The thumbnail is the first byte(s) of every compressed block: luma (1 byte, or 2 in
    /// Superfine) then all chroma blocks (2 bytes each). Decoding just the DC terms gives a
    /// 1/8-scale picture: 80×60 for Superfine/Fine, 40×30 for Normal.
    func decodeThumbnail(_ data: Data, resolution: Resolution) throws -> RGBImage {
        guard let P = modes[resolution.rawValue] else { throw DecodeError.unknownResolution(resolution.rawValue) }
        let gh = P.height / 8, gw = P.width / 16, ch = P.height / 16, cw = P.width / 16
        let ny = gh * gw, nc = 2 * ch * cw
        let raw = [UInt8](data)
        let yb = raw.count >= ny * 2 + nc * 2 ? 2 : 1
        guard raw.count >= ny * yb + nc * 2 else { throw DecodeError.tooShort }

        func dcs(_ start: Int, _ n: Int, _ bpb: Int, _ p: PlaneParams) -> [Double] {
            raw.withUnsafeBufferPointer { b in
                (0..<n).map { i in
                    let v = Self.field(b, base: start + i * bpb, pos: 0, len: p.dcLen, limit: bpb * 8, signed: p.dcSigned)
                    return Double(v) * p.a0 + p.a1
                }
            }
        }
        let yv = dcs(0, ny, yb, P.y).map { $0 / 128.0.squareRoot() }
        let crv = dcs(ny * yb, nc / 2, 2, P.cr).map { $0 / 8 }
        let cbv = dcs(ny * yb + nc, nc / 2, 2, P.cb).map { $0 / 8 }

        let W = gw * 2, H = gh            // luma blocks are 8×16, so double horizontally
        var Y = [Double](repeating: 0, count: W * H)
        for r in 0..<gh { for c in 0..<gw { Y[r * W + 2 * c] = yv[r * gw + c]; Y[r * W + 2 * c + 1] = yv[r * gw + c] } }
        let Cr = Self.repeat2x(crv, w: cw, h: ch), Cb = Self.repeat2x(cbv, w: cw, h: ch)
        return Self.toRGB(Y: Y, Cb: Cb, Cr: Cr, w: W, h: H)
    }

    // MARK: Helpers

    private static func repeat2x(_ a: [Double], w: Int, h: Int) -> [Double] {
        var out = [Double](repeating: 0, count: w * h * 4)
        for y in 0..<(h * 2) { for x in 0..<(w * 2) { out[y * w * 2 + x] = a[(y / 2) * w + x / 2] } }
        return out
    }

    /// Pillow's BILINEAR resize for float images (triangle filter, pixel-centre aligned,
    /// weights renormalised at the edges), horizontal pass then vertical pass.
    static func resizeBilinear(_ src: [Double], w: Int, h: Int, outW: Int, outH: Int) -> [Double] {
        func coeffs(_ inSize: Int, _ outSize: Int) -> [(Int, [Double])] {
            let scale = Double(inSize) / Double(outSize)
            let fscale = max(scale, 1.0)
            let support = 1.0 * fscale
            return (0..<outSize).map { xx in
                let center = (Double(xx) + 0.5) * scale
                var xmin = Int(center - support + 0.5); if xmin < 0 { xmin = 0 }
                var xmax = Int(center + support + 0.5); if xmax > inSize { xmax = inSize }
                xmax -= xmin
                var ws = (0..<xmax).map { x -> Double in
                    let t = abs((Double(x + xmin) - center + 0.5) / fscale)
                    return t < 1 ? 1 - t : 0
                }
                let total = ws.reduce(0, +)
                if total != 0 { ws = ws.map { $0 / total } }
                return (xmin, ws)
            }
        }
        let hc = coeffs(w, outW), vc = coeffs(h, outH)
        var tmp = [Double](repeating: 0, count: outW * h)
        for y in 0..<h {
            for x in 0..<outW {
                let (x0, ws) = hc[x]; var s = 0.0
                for k in 0..<ws.count { s += src[y * w + x0 + k] * ws[k] }
                tmp[y * outW + x] = s
            }
        }
        var out = [Double](repeating: 0, count: outW * outH)
        for y in 0..<outH {
            let (y0, ws) = vc[y]
            for x in 0..<outW {
                var s = 0.0
                for k in 0..<ws.count { s += tmp[(y0 + k) * outW + x] * ws[k] }
                out[y * outW + x] = s
            }
        }
        return out
    }

    /// Learned 5×5 linear filter with edge padding, taps ordered dy then dx, plus a bias term.
    private static func filter5x5(_ p: [Double], w: Int, h: Int, weights: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var s = weights[25]
                var k = 0
                for dy in -2...2 {
                    let yy = min(max(y + dy, 0), h - 1) * w
                    for dx in -2...2 {
                        s += p[yy + min(max(x + dx, 0), w - 1)] * weights[k]
                        k += 1
                    }
                }
                out[y * w + x] = s
            }
        }
        return out
    }

    private static func toRGB(Y: [Double], Cb: [Double], Cr: [Double], w: Int, h: Int) -> RGBImage {
        var px = [UInt8](repeating: 0, count: w * h * 3)
        @inline(__always) func clip(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 255).rounded(.toNearestOrEven)) }
        for i in 0..<(w * h) {
            let R = Y[i] + Cr[i] / 0.713
            let B = Y[i] + Cb[i] / 0.564
            let G = (Y[i] - 0.299 * R - 0.114 * B) / 0.587
            px[i * 3] = clip(R); px[i * 3 + 1] = clip(G); px[i * 3 + 2] = clip(B)
        }
        return RGBImage(width: w, height: h, pixels: px)
    }
}

/// The 384-byte header the original software writes in front of raw image data.
func dctHeader(rawLength: Int, resolution: Resolution) -> Data {
    var h = [UInt8](repeating: 0, count: 384)
    h[0] = 0x43; h[1] = 0x64; h[2] = 0x63; h[3] = 0x78   // "Cdcx"
    h[7] = 0x02
    h[8] = 0x80
    let blocks = rawLength / 256 - 1
    h[9] = UInt8(blocks & 0xFF); h[10] = UInt8((blocks >> 8) & 0xFF)
    h[12] = UInt8(resolution.rawValue)
    return Data(h)
}
