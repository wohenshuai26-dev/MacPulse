// Generates custom SF Symbols for the Control Center controls: a small pictogram
// (thermometer / CPU chip / memory module) stacked above the value, e.g. "62°".
// A 1×1 control only shows its icon, so the value has to live inside the symbol.
//
// Usage: swift tools/make_symbols.swift <output .xcassets dir> [preview.png]
import AppKit
import CoreText

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "Controls/Assets.xcassets")

// MARK: - Geometry helpers (font units, y up, baseline at 0, cap height ≈ 70.46)

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: desc, size: size) ?? base) as CTFont
}

func outline(_ text: String, _ f: CTFont) -> (path: CGPath, advance: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<n {
            if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                path.addPath(g, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
            }
        }
    }
    return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
}
func union(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1, using: .winding) }
}

// MARK: - Pictograms (drawn ~SF Symbols "regular" stroke weight)

let stroke: CGFloat = 7

/// Thermometer: stem + bulb outline with a "mercury" column inside.
func thermometer() -> CGPath {
    let outer = union([rrect(-12, 14, 24, 52, 12), circle(0, 0, 18)])
    let inner = union([rrect(-12 + stroke, 14, 24 - 2 * stroke, 52 - stroke, 12 - stroke), circle(0, 0, 18 - stroke)])
    let shell = outer.subtracting(inner, using: .winding)
    let mercury = union([circle(0, 0, 6), rrect(-2.5, 0, 5, 36, 2.5)])
    return shell.union(mercury, using: .winding)
}

/// CPU chip: rounded square, inner die, three pins per side.
func chip() -> CGPath {
    let s: CGFloat = 46, r: CGFloat = 8
    let body = rrect(-s / 2, -s / 2, s, s, r).subtracting(rrect(-s / 2 + stroke, -s / 2 + stroke, s - 2 * stroke, s - 2 * stroke, r - stroke / 2), using: .winding)
    var parts: [CGPath] = [body, rrect(-9, -9, 18, 18, 3)]
    let pinLen: CGFloat = 8, pinW: CGFloat = 5
    for o in [-13.0, 0, 13] as [CGFloat] {
        parts.append(rrect(o - pinW / 2, s / 2 - 1, pinW, pinLen, 1.5))           // top
        parts.append(rrect(o - pinW / 2, -s / 2 - pinLen + 1, pinW, pinLen, 1.5)) // bottom
        parts.append(rrect(s / 2 - 1, o - pinW / 2, pinLen, pinW, 1.5))           // right
        parts.append(rrect(-s / 2 - pinLen + 1, o - pinW / 2, pinLen, pinW, 1.5)) // left
    }
    return union(parts)
}

/// Memory module: wide board with three chips and a row of contacts.
func memory() -> CGPath {
    let w: CGFloat = 70, h: CGFloat = 34, r: CGFloat = 6
    let board = rrect(-w / 2, -h / 2, w, h, r).subtracting(rrect(-w / 2 + stroke, -h / 2 + stroke, w - 2 * stroke, h - 2 * stroke, r - stroke / 2), using: .winding)
    var parts: [CGPath] = [board]
    for i in 0..<3 { parts.append(rrect(-24 + CGFloat(i) * 17, -6, 14, 12, 2.5)) }
    for i in 0..<6 { parts.append(rrect(-26 + CGFloat(i) * 10, -h / 2 - 8, 4.5, 9, 1.5)) }
    return union(parts)
}

/// Fan: three swept blades around a hub.
func fan() -> CGPath {
    var blades: [CGPath] = []
    for i in 0..<3 {
        let blade = CGPath(ellipseIn: CGRect(x: -8.5, y: 5, width: 17, height: 30), transform: nil)
        // Sweep the blade around its own centre, then place it around the hub.
        var t = CGAffineTransform(rotationAngle: CGFloat(i) * 2 * .pi / 3)
            .translatedBy(x: 0, y: 20).rotated(by: -0.5).translatedBy(x: 0, y: -20)
        blades.append(blade.copy(using: &t)!)
    }
    let gap = circle(0, 0, 9.5)
    return union(blades).subtracting(gap, using: .winding).union(circle(0, 0, 6), using: .winding)
}

// MARK: - Composite symbol

let numberFont = roundedFont(100, .semibold)
let unitFont = roundedFont(56, .semibold)
let capHeight = CTFontGetCapHeight(numberFont)
let unitCap = CTFontGetCapHeight(unitFont)

/// Pictogram (scaled to `glyphHeight`) centred above the value; the whole stack is
/// centred on the cap-height midline so it sits like a normal symbol.
func composite(text: String, unit: String, glyph: CGPath, glyphHeight: CGFloat) -> CGPath {
    let num = outline(text, numberFont)
    let value = CGMutablePath()
    value.addPath(num.path)
    let u = outline(unit, unitFont)
    let ub = u.path.boundingBoxOfPath
    let unitTop = unit == "°" ? ub.maxY : unitCap
    value.addPath(u.path, transform: CGAffineTransform(translationX: num.advance + 3, y: capHeight - unitTop))
    let vb = value.boundingBoxOfPath

    let gap: CGFloat = 14
    let gb = glyph.boundingBoxOfPath
    let k = glyphHeight / gb.height
    var gt = CGAffineTransform(translationX: vb.midX, y: capHeight + gap)
        .scaledBy(x: k, y: k)
        .translatedBy(x: -gb.midX, y: -gb.minY)
    let placedGlyph = glyph.copy(using: &gt)!

    let all = CGMutablePath()
    all.addPath(value)
    all.addPath(placedGlyph)
    // Centre the stack vertically on the cap-height midline.
    let total = all.boundingBoxOfPath
    let shift = capHeight / 2 - total.midY
    var t = CGAffineTransform(translationX: 0, y: shift)
    return all.copy(using: &t)!
}

// MARK: - SVG template

func fmt(_ v: CGFloat) -> String {
    let s = String(format: "%.2f", v)
    return s.hasSuffix(".00") ? String(s.dropLast(3)) : s
}

func svgPathData(_ p: CGPath, dx: CGFloat) -> String {
    var d = ""
    p.applyWithBlock { el in
        let e = el.pointee
        func pt(_ i: Int) -> String { "\(fmt(e.points[i].x + dx)) \(fmt(-e.points[i].y))" }
        switch e.type {
        case .moveToPoint: d += "M\(pt(0))"
        case .addLineToPoint: d += "L\(pt(0))"
        case .addQuadCurveToPoint: d += "Q\(pt(0)) \(pt(1))"
        case .addCurveToPoint: d += "C\(pt(0)) \(pt(1)) \(pt(2))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

let baselineM: CGFloat = 1126, caplineM: CGFloat = 1055.54, originX: CGFloat = 1400

func template(_ path: CGPath) -> String {
    let box = path.boundingBoxOfPath
    let d = svgPathData(path, dx: -box.minX)
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <!--glyph: "", point size: 100.0, template writer version: "MacPulse"-->
     <g id="Notes">
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
      <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 2952 1933)">Template v.3.0</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
      <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
      <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="\(fmt(baselineM))" y2="\(fmt(baselineM))"/>
      <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="\(fmt(caplineM))" y2="\(fmt(caplineM))"/>
      <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
      <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
      <line id="left-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(fmt(originX))" x2="\(fmt(originX))" y1="1030.79" y2="1150.12"/>
      <line id="right-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(fmt(originX + box.width))" x2="\(fmt(originX + box.width))" y1="1030.79" y2="1150.12"/>
     </g>
     <g id="Symbols">
      <g id="Regular-M">
       <g transform="matrix(1 0 0 1 \(fmt(originX)) \(fmt(baselineM)))">
        <path d="\(d)"/>
       </g>
      </g>
     </g>
    </svg>

    """
}

// MARK: - Output

struct SymbolSet {
    let prefix: String; let unit: String; let range: ClosedRange<Int>; let glyph: CGPath; let glyphHeight: CGFloat
    var label: (Int) -> String = { String($0) }
}
let sets = [
    SymbolSet(prefix: "mp.temp", unit: "°", range: 0...120, glyph: thermometer(), glyphHeight: 58), // CPU °C
    SymbolSet(prefix: "mp.pct", unit: "%", range: 0...100, glyph: chip(), glyphHeight: 46),         // CPU usage %
    SymbolSet(prefix: "mp.gb", unit: "G", range: 0...192, glyph: memory(), glyphHeight: 42),        // memory used GB
    SymbolSet(prefix: "mp.fan", unit: "k", range: 0...99, glyph: fan(), glyphHeight: 48,            // fan, hundreds of RPM
              label: { "\($0 / 10).\($0 % 10)" }),
]

let fm = FileManager.default
try? fm.removeItem(at: out)
try! fm.createDirectory(at: out, withIntermediateDirectories: true)
try! #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
var count = 0
for set in sets {
    for n in set.range {
        let name = "\(set.prefix).\(n)"
        let dir = out.appendingPathComponent("\(name).symbolset")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! template(composite(text: set.label(n), unit: set.unit, glyph: set.glyph, glyphHeight: set.glyphHeight))
            .write(to: dir.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
        try! """
        {
          "info" : { "author" : "xcode", "version" : 1 },
          "symbols" : [ { "filename" : "\(name).svg", "idiom" : "universal" } ]
        }

        """.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        count += 1
    }
}
print("wrote \(count) symbols to \(out.path)")
