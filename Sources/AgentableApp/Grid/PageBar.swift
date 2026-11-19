import SwiftUI
import AgentableCore

/// Under the table, as on board 15: which rows are on screen out of how many, the page, and
/// previous and next (⌘[ and ⌘]). The page button opens jump-to-page, rows per page and an
/// exact count.
struct PageBar: View {
    @Bindable var grid: GridModel
    @Binding var popover: FilterPopover?
    @State private var frame = CGRect.zero

    var body: some View {
        HStack(spacing: 10) {
            rangeText
            Spacer(minLength: 8)
            Button {
                popover = popover?.kind == .pages ? nil : FilterPopover(kind: .pages, anchor: frame)
            } label: {
                HStack(spacing: 4) {
                    Text("Page")
                    Text((grid.page + 1).grouped).font(.mono(12))
                    if let pages = grid.pageCount {
                        Text("of")
                        Text((grid.countIsEstimate ? "~" : "") + pages.grouped).font(.mono(12))
                    }
                }
                .font(.ui(12))
                .foregroundStyle(Color.tmText)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(popover?.kind == .pages ? Color.tmChip : Color.tmWindow, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.tmLine))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to a page, change rows per page")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { new in
                frame = new
                if SnapshotHooks.openPages, new.width > 0 {
                    SnapshotHooks.openPages = false
                    // Once the bars under the table have settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { popover = FilterPopover(kind: .pages, anchor: frame) }
                }
            }
            arrow(.chevronLeft, "Previous page (⌘[)", enabled: grid.page > 0) { grid.showPage(grid.page - 1) }
                .keyboardShortcut("[", modifiers: .command)
            arrow(.chevronRight, "Next page (⌘])", enabled: grid.hasNextPage) { grid.showPage(grid.page + 1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(Color.tmWindow)
        .overlay(alignment: .top) { Hairline() }
    }

    /// "1,201–1,400 of ~1,204,213 rows"; with a filter, "of 37 matching".
    private var rangeText: some View {
        let first = grid.pageStart + 1
        let last = grid.pageStart + grid.pageRowCount
        let total: String = {
            if let known = grid.knownCount { return (grid.countIsEstimate ? "~" : "") + known.grouped }
            return grid.counting ? "…" : "\(grid.loadedEnd.grouped)+"
        }()
        let unfiltered = grid.filter.isEmpty && grid.search.isEmpty
        return HStack(spacing: 4) {
            Text(verbatim: grid.pageRowCount == 0 ? "0" : "\(first.grouped)–\(last.grouped)").foregroundStyle(Color.tmText2).fontWeight(.medium)
            Text(unfiltered ? String(localized: "of \(total) rows") : String(localized: "of \(total) matching")).foregroundStyle(Color.tmMuted)
        }
        .font(.mono(12))
        .lineLimit(1)
    }

    private func arrow(_ icon: Icon, _ help: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon, size: 14)
                .foregroundStyle(enabled ? Color.tmText2 : Color.tmMuted.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.tmLine))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Jump to a page, pick rows per page, and turn an estimate into an exact count.
struct PagesPanel: View {
    @Bindable var grid: GridModel
    let onDone: () -> Void
    @State private var target = ""
    @State private var custom = ""
    @FocusState private var focused: Field?

    enum Field { case page, size }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Go to page")
                HStack(spacing: 8) {
                    FieldBox(height: 30, focused: focused == .page) {
                        TextField(String(grid.page + 1), text: $target)
                            .textFieldStyle(.plain).font(.mono(12.5))
                            .focused($focused, equals: .page)
                            .onSubmit(go)
                    }
                    Button("Go", action: go)
                        .buttonStyle(.primary(height: 30))
                        .disabled(Int(target.filter(\.isNumber)) == nil)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Rows per page")
                SegmentedSwitch(
                    options: GridModel.pageSizes.map { ($0, String($0)) },
                    selection: Binding(get: { grid.rowsPerPage }, set: { grid.setRowsPerPage($0) }),
                    height: 24,
                    fill: true
                )
                HStack(spacing: 8) {
                    FieldBox(height: 30, focused: focused == .size) {
                        TextField("Other, like 25", text: $custom)
                            .textFieldStyle(.plain).font(.mono(12.5))
                            .focused($focused, equals: .size)
                            .onSubmit(setSize)
                        Text("rows").font(.ui(12)).foregroundStyle(Color.tmMuted)
                    }
                    Button("Set", action: setSize)
                        .buttonStyle(.secondary(height: 30))
                        .disabled(customSize == nil)
                }
            }
            if grid.countIsEstimate || grid.knownCount == nil {
                HStack(spacing: 8) {
                    Text(grid.counting ? "Counting…" : "The total is an estimate.")
                        .font(.ui(12)).foregroundStyle(Color.tmMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Count exactly") { grid.countExactly() }
                        .buttonStyle(.secondary(height: 26))
                        .font(.ui(12))
                        .disabled(grid.counting)
                }
                .padding(.top, 10)
                .overlay(alignment: .top) { Hairline(color: .tmLine2) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            focused = .page
            if !GridModel.pageSizes.contains(grid.rowsPerPage) { custom = String(grid.rowsPerPage) }
        }
    }

    /// A typed size, when it is a whole number in range.
    private var customSize: Int? {
        Int(custom.filter(\.isNumber)).flatMap { GridModel.pageSizeRange.contains($0) ? $0 : nil }
    }

    private func setSize() {
        guard let size = customSize else { return }
        grid.setRowsPerPage(size)
    }

    private func go() {
        guard let number = Int(target.filter(\.isNumber)), number >= 1 else { return }
        var page = number - 1
        if let pages = grid.pageCount, !grid.countIsEstimate { page = min(page, pages - 1) }
        grid.showPage(page)
        onDone()
    }
}
