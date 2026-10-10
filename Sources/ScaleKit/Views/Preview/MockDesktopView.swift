import SwiftUI

/// An illustrative slice of a desktop — menu bar, a Finder-style window and a
/// code editor — drawn at `scale` points per point of the current interface.
/// Sizes are multiplied explicitly (not with `scaleEffect`) so text stays crisp.
struct MockDesktopView: View {
    let scale: CGFloat

    var body: some View {
        let s = max(0.25, scale)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.20, green: 0.33, blue: 0.60),
                        Color(red: 0.47, green: 0.36, blue: 0.66),
                        Color(red: 0.86, green: 0.56, blue: 0.52),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                MockFinderWindow(s: s)
                    .fixedSize()
                    .offset(x: 28 * s, y: 50 * s)

                MockEditorWindow(s: s)
                    .fixedSize()
                    .offset(x: 692 * s, y: 76 * s)

                MockMenuBar(s: s)
                    .frame(width: proxy.size.width)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustrative desktop drawn at \(Int((scale * 100).rounded())) percent of the current size")
    }
}

// MARK: - Pieces

private struct MockMenuBar: View {
    let s: CGFloat

    var body: some View {
        HStack(spacing: 16 * s) {
            Image(systemName: "apple.logo")
                .font(.system(size: 14 * s, weight: .medium))
            Text("Finder")
                .font(.system(size: 13 * s, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { item in
                Text(item).font(.system(size: 13 * s))
            }
            Spacer(minLength: 0)
            Group {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
                Text("Fri 9:41")
            }
            .font(.system(size: 13 * s))
        }
        .lineLimit(1)
        .padding(.horizontal, 14 * s)
        .frame(height: 26 * s)
        .background(.ultraThinMaterial)
    }
}

private struct TrafficLights: View {
    let s: CGFloat

    var body: some View {
        HStack(spacing: 8 * s) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
        }
        .frame(width: 52 * s, height: 12 * s)
    }
}

private struct MockFinderWindow: View {
    let s: CGFloat

    private let sidebar: [(String, String)] = [
        ("clock", "Recents"), ("square.grid.2x2", "Applications"), ("menubar.dock.rectangle", "Desktop"),
        ("doc", "Documents"), ("arrow.down.circle", "Downloads"), ("icloud", "iCloud Drive"),
    ]

    private let files: [(String, String, String, String)] = [
        ("folder.fill", "Projects", "Today, 9:41", "—"),
        ("doc.text.fill", "Meeting notes.md", "Yesterday", "4 KB"),
        ("photo.fill", "Screenshot.png", "8 Oct", "2.1 MB"),
        ("doc.richtext.fill", "Proposal.pdf", "6 Oct", "860 KB"),
        ("tablecells.fill", "Budget.numbers", "2 Oct", "312 KB"),
        ("music.note", "Demo.m4a", "28 Sep", "5.4 MB"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10 * s) {
                TrafficLights(s: s)
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Text("Documents").font(.system(size: 13 * s, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2")
                Image(systemName: "list.bullet")
                Image(systemName: "magnifyingglass")
            }
            .font(.system(size: 13 * s, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14 * s)
            .frame(height: 44 * s)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2 * s) {
                    Text("Favourites")
                        .font(.system(size: 11 * s, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10 * s)
                        .padding(.bottom, 2 * s)
                    ForEach(Array(sidebar.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 7 * s) {
                            Image(systemName: item.0)
                                .font(.system(size: 13 * s))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18 * s)
                            Text(item.1).font(.system(size: 13 * s))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10 * s)
                        .frame(height: 26 * s)
                        .background(
                            index == 3 ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6 * s, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10 * s)
                .padding(.horizontal, 8 * s)
                .frame(width: 176 * s)
                .background(Color.primary.opacity(0.035))

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Name")
                        Spacer(minLength: 0)
                        Text("Date Modified").frame(width: 110 * s, alignment: .leading)
                        Text("Size").frame(width: 56 * s, alignment: .trailing)
                    }
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12 * s)
                    .frame(height: 26 * s)

                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: 8 * s) {
                            Image(systemName: file.0)
                                .font(.system(size: 13 * s))
                                .foregroundStyle(index == 0 ? Color.accentColor : .secondary)
                                .frame(width: 18 * s)
                            Text(file.1)
                            Spacer(minLength: 0)
                            Text(file.2).foregroundStyle(.secondary).frame(width: 110 * s, alignment: .leading)
                            Text(file.3).foregroundStyle(.secondary).frame(width: 56 * s, alignment: .trailing)
                        }
                        .font(.system(size: 13 * s))
                        .lineLimit(1)
                        .padding(.horizontal, 12 * s)
                        .frame(height: 24 * s)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
                    }

                    Divider().padding(.vertical, 10 * s)

                    Text("Body text at the system size. At larger interface sizes every glyph uses more pixels, so text is easier to read but fewer lines fit on screen.")
                        .font(.system(size: 13 * s))
                        .lineSpacing(3 * s)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14 * s)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: 640 * s, height: 420 * s)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10 * s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18 * s, y: 8 * s)
    }
}

private struct MockEditorWindow: View {
    let s: CGFloat

    private static let keyword = Color(red: 0.99, green: 0.37, blue: 0.64)
    private static let typeName = Color(red: 0.36, green: 0.85, blue: 0.94)
    private static let string = Color(red: 0.99, green: 0.57, blue: 0.43)
    private static let number = Color(red: 0.82, green: 0.75, blue: 0.47)
    private static let comment = Color(white: 0.5)
    private static let plain = Color(white: 0.9)

    private static let lines: [[(String, Color)]] = [
        [("import", keyword), (" SwiftUI", plain)],
        [],
        [("// Interface size relative to native", comment)],
        [("struct", keyword), (" Preview", typeName), (": ", plain), ("View", typeName), (" {", plain)],
        [("    let", keyword), (" scale", plain), (": ", plain), ("Double", typeName), (" = ", plain), ("1.5", number)],
        [],
        [("    var", keyword), (" body", plain), (": ", plain), ("some", keyword), (" View", typeName), (" {", plain)],
        [("        Text", typeName), ("(", plain), ("\"Hello, ultrawide\"", string), (")", plain)],
        [("            .font", plain), ("(.", plain), ("system", plain), ("(size: ", plain), ("13", number), (" * scale))", plain)],
        [("    }", plain)],
        [("}", plain)],
        [],
        [("let", keyword), (" columns", plain), (" = ", plain), ("Int", typeName), ("(width / ", plain), ("7.8", number), (")", plain)],
        [("let", keyword), (" lines", plain), (" = ", plain), ("Int", typeName), ("(height / ", plain), ("19", number), (")", plain)],
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10 * s) {
                TrafficLights(s: s)
                Text("Preview.swift")
                    .font(.system(size: 12 * s, weight: .medium))
                    .foregroundStyle(Color(white: 0.75))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12 * s)
            .frame(height: 32 * s)
            .background(Color(white: 0.17))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.lines.enumerated()), id: \.offset) { index, tokens in
                    HStack(spacing: 0) {
                        Text("\(index + 1)")
                            .foregroundStyle(Color(white: 0.4))
                            .frame(width: 30 * s, alignment: .trailing)
                            .padding(.trailing, 16 * s)
                        ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                            Text(token.0).foregroundStyle(token.1)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13 * s, design: .monospaced))
                    .lineLimit(1)
                    .frame(height: 19 * s)
                }
            }
            .padding(.vertical, 10 * s)
            Spacer(minLength: 0)
        }
        .frame(width: 560 * s, height: 380 * s)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10 * s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18 * s, y: 8 * s)
        .environment(\.colorScheme, .dark)
    }
}
