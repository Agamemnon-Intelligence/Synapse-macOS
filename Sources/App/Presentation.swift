import Foundation

/// Writes .pptx files (Office Open XML) without any third-party library: the XML parts are
/// generated here and zipped with the system `zip`. Opens in Keynote, PowerPoint and Quick Look.
enum PresentationWriter {
    struct Slide {
        var title: String
        var bullets: [String]
        var notes: String?
    }

    struct Theme {
        let background, title, body, accent, muted: String
        static let dark = Theme(background: "0B0D12", title: "FFFFFF", body: "CBD5E1", accent: "38BDF8", muted: "64748B")
        static let light = Theme(background: "FFFFFF", title: "0F172A", body: "334155", accent: "0EA5E9", muted: "94A3B8")
        static let warm = Theme(background: "FBF7F2", title: "1F1A17", body: "4A403A", accent: "F97316", muted: "A8A29E")
    }

    static let width = 12_192_000, height = 6_858_000   // 16:9 in EMU

    static func write(title: String, subtitle: String?, slides: [Slide], theme: Theme, to url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }

        var files: [String: String] = [:]
        let allSlides = [Slide(title: title, bullets: subtitle.map { [$0] } ?? [], notes: nil)] + slides
        let count = allSlides.count

        files["[Content_Types].xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \((1...count).map { "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined(separator: "\n"))
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """

        files["_rels/.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """

        let now = ISO8601DateFormatter().string(from: Date())
        files["docProps/core.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(esc(title))</dc:title><dc:creator>Synapse</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
        files["docProps/app.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Synapse</Application><Slides>\(count)</Slides></Properties>
        """

        files["ppt/presentation.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="\(ns.a)" xmlns:r="\(ns.r)" xmlns:p="\(ns.p)" saveSubsetFonts="1">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\((1...count).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined())</p:sldIdLst>
        <p:sldSz cx="\(width)" cy="\(height)"/><p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
        files["ppt/_rels/presentation.xml.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="\(ns.rel)/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        <Relationship Id="rId2" Type="\(ns.rel)/theme" Target="theme/theme1.xml"/>
        \((1...count).map { "<Relationship Id=\"rId\($0 + 2)\" Type=\"\(ns.rel)/slide\" Target=\"slides/slide\($0).xml\"/>" }.joined(separator: "\n"))
        </Relationships>
        """

        let emptyTree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>"
        files["ppt/slideMasters/slideMaster1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="\(ns.a)" xmlns:r="\(ns.r)" xmlns:p="\(ns.p)">
        <p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="\(theme.background)"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>\(emptyTree)</p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        <p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4000"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="2000"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles>
        </p:sldMaster>
        """
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="\(ns.rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="\(ns.rel)/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
        files["ppt/slideLayouts/slideLayout1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="\(ns.a)" xmlns:r="\(ns.r)" xmlns:p="\(ns.p)" type="blank" preserve="1">
        <p:cSld name="Blank">\(emptyTree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="\(ns.rel)/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
        files["ppt/theme/theme1.xml"] = themeXML(theme)

        for (i, slide) in allSlides.enumerated() {
            files["ppt/slides/slide\(i + 1).xml"] = i == 0 ? titleSlide(slide, theme: theme) : contentSlide(slide, number: i, total: count - 1, theme: theme)
            files["ppt/slides/_rels/slide\(i + 1).xml.rels"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="\(ns.rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """
        }

        for (path, content) in files {
            let dest = work.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: dest, atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = runProcess("/usr/bin/zip", ["-X", "-q", "-r", url.path, "[Content_Types].xml", "_rels", "docProps", "ppt"], cwd: work, timeout: 60)
        guard r.status == 0, fm.fileExists(atPath: url.path) else { throw APIError(status: 0, message: "Couldn't package the presentation: \(r.output)") }
    }

    // MARK: Slides

    private static func titleSlide(_ s: Slide, theme: Theme) -> String {
        var shapes = rect(id: 2, x: 760_000, y: 2_540_000, w: 120_000, h: 1_780_000, color: theme.accent)
        shapes += textBox(id: 3, x: 1_100_000, y: 2_300_000, w: 10_000_000, h: 1_500_000,
                          paragraphs: [run(s.title, size: 5200, color: theme.title, bold: true)], anchor: "b")
        if let sub = s.bullets.first {
            shapes += textBox(id: 4, x: 1_100_000, y: 3_850_000, w: 10_000_000, h: 900_000,
                              paragraphs: [run(sub, size: 2200, color: theme.body, bold: false)], anchor: "t")
        }
        return slideXML(shapes, theme: theme)
    }

    private static func contentSlide(_ s: Slide, number: Int, total: Int, theme: Theme) -> String {
        var shapes = rect(id: 2, x: 760_000, y: 700_000, w: 900_000, h: 70_000, color: theme.accent)
        shapes += textBox(id: 3, x: 760_000, y: 860_000, w: 10_600_000, h: 1_000_000,
                          paragraphs: [run(s.title, size: 3600, color: theme.title, bold: true)], anchor: "t")
        let size = s.bullets.count > 6 ? 1800 : 2200
        let bullets = s.bullets.map { b in
            "<a:p><a:pPr marL=\"342900\" indent=\"-342900\"><a:spcBef><a:spcPts val=\"900\"/></a:spcBef><a:buClr><a:srgbClr val=\"\(theme.accent)\"/></a:buClr><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>"
            + "<a:r><a:rPr lang=\"en-US\" sz=\"\(size)\" dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(theme.body)\"/></a:solidFill><a:latin typeface=\"Helvetica Neue\"/></a:rPr><a:t>\(esc(b))</a:t></a:r></a:p>"
        }
        shapes += textBox(id: 4, x: 760_000, y: 2_000_000, w: 10_600_000, h: 4_200_000, paragraphs: bullets, anchor: "t", raw: true)
        shapes += textBox(id: 5, x: 10_400_000, y: 6_250_000, w: 1_000_000, h: 400_000,
                          paragraphs: [run("\(number) / \(total)", size: 1100, color: theme.muted, bold: false, align: "r")], anchor: "ctr")
        return slideXML(shapes, theme: theme)
    }

    private static func slideXML(_ shapes: String, theme: Theme) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="\(ns.a)" xmlns:r="\(ns.r)" xmlns:p="\(ns.p)">
        <p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="\(theme.background)"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
        <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\(shapes)</p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func rect(id: Int, x: Int, y: Int, w: Int, h: Int, color: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Accent \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>"
    }

    private static func run(_ text: String, size: Int, color: String, bold: Bool, align: String = "l") -> String {
        "<a:p><a:pPr algn=\"\(align)\"/><a:r><a:rPr lang=\"en-US\" sz=\"\(size)\" b=\"\(bold ? 1 : 0)\" dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill><a:latin typeface=\"Helvetica Neue\"/></a:rPr><a:t>\(esc(text))</a:t></a:r></a:p>"
    }

    private static func textBox(id: Int, x: Int, y: Int, w: Int, h: Int, paragraphs: [String], anchor: String, raw: Bool = false) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"
        + "<p:txBody><a:bodyPr wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"\(anchor)\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>"
    }

    private static func themeXML(_ t: Theme) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="\(ns.a)" name="Synapse">
        <a:themeElements>
        <a:clrScheme name="Synapse">
        <a:dk1><a:srgbClr val="\(t.title == "FFFFFF" ? "0B0D12" : t.title)"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="1E293B"/></a:dk2><a:lt2><a:srgbClr val="F1F5F9"/></a:lt2>
        <a:accent1><a:srgbClr val="\(t.accent)"/></a:accent1><a:accent2><a:srgbClr val="14B8A6"/></a:accent2>
        <a:accent3><a:srgbClr val="F97316"/></a:accent3><a:accent4><a:srgbClr val="22C55E"/></a:accent4>
        <a:accent5><a:srgbClr val="EAB308"/></a:accent5><a:accent6><a:srgbClr val="EF4444"/></a:accent6>
        <a:hlink><a:srgbClr val="0EA5E9"/></a:hlink><a:folHlink><a:srgbClr val="0284C7"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Synapse"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>
        <a:fmtScheme name="Synapse">
        <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
        <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
        <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
        </a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }

    private enum ns {
        static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .filter { $0 == "\n" || $0 == "\t" || !($0.asciiValue.map { $0 < 32 } ?? false) }
    }
}
