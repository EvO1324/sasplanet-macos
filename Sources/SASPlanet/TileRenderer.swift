import AppKit

enum TileRenderer {
    static func drawImage(_ ctx: CGContext, _ img: CGImage, _ r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    static func draw(_ m: MapType, ctx: CGContext, zoom: Int, origin: CGPoint, vis: CGRect,
                     usePrev: Bool, want: inout Set<TileKey>, provider: TileProvider = .shared) {
        let n = 1 << zoom
        let ts = CGFloat(Geo.tileSize)
        let tx0 = max(0, Int(floor((origin.x + vis.minX) / ts)))
        let tx1 = min(n - 1, Int(floor((origin.x + vis.maxX - 0.01) / ts)))
        let ty0 = max(0, Int(floor((origin.y + vis.minY) / ts)))
        let ty1 = min(n - 1, Int(floor((origin.y + vis.maxY - 0.01) / ts)))
        guard tx0 <= tx1, ty0 <= ty1 else { return }
        let srcZ = min(zoom, m.maxZoom)

        for ty in ty0...ty1 {
            for tx in tx0...tx1 {
                let r = CGRect(x: CGFloat(tx) * ts - origin.x, y: CGFloat(ty) * ts - origin.y, width: ts, height: ts)
                if srcZ == zoom {
                    let k = TileKey(mapId: m.id, x: tx, y: ty, z: zoom)
                    want.insert(k)
                    if let img = provider.image(k) {
                        ctx.interpolationQuality = .default
                        drawImage(ctx, img, r)
                        continue
                    }
                    provider.request(k)
                    if !usePrev { continue }
                }
                var d = max(1, zoom - srcZ)
                let firstD = d
                while d <= min(zoom, 8) {
                    let pz = zoom - d, px = tx >> d, py = ty >> d
                    let pk = TileKey(mapId: m.id, x: px, y: py, z: pz)
                    if let pimg = provider.image(pk) {
                        let sub = CGFloat(pimg.width) / CGFloat(1 << d)
                        let crop = CGRect(x: CGFloat(tx - (px << d)) * sub, y: CGFloat(ty - (py << d)) * sub,
                                          width: sub, height: sub)
                        if let c = pimg.cropping(to: crop) {
                            ctx.interpolationQuality = .medium
                            drawImage(ctx, c, r)
                        }
                        if d == firstD && srcZ < zoom { want.insert(pk) }
                        break
                    }
                    if d == firstD && srcZ < zoom {
                        want.insert(pk)
                        provider.request(pk)
                        if !usePrev { break }
                    }
                    d += 1
                }
            }
        }
    }
}
