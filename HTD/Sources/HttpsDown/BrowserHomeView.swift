import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BookmarkDropTarget: Equatable {
    let categoryID: UUID?
    let index: Int
}

struct BookmarkItemGeometry: Equatable {
    let id: UUID
    let categoryID: UUID?
    let index: Int
    let frame: CGRect
}

struct BookmarkItemGeometryPreferenceKey: PreferenceKey {
    static var defaultValue: [BookmarkItemGeometry] = []
    static func reduce(value: inout [BookmarkItemGeometry], nextValue: () -> [BookmarkItemGeometry]) {
        value.append(contentsOf: nextValue())
    }
}

struct CategorySectionGeometry: Equatable {
    let categoryID: UUID?
    let frame: CGRect
    let count: Int
}

struct CategorySectionGeometryPreferenceKey: PreferenceKey {
    static var defaultValue: [CategorySectionGeometry] = []
    static func reduce(value: inout [CategorySectionGeometry], nextValue: () -> [CategorySectionGeometry]) {
        value.append(contentsOf: nextValue())
    }
}

struct BrowserHomeView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: LoginBrowserModel
    @ObservedObject var preferences: BrowserPreferences
    var onOpenNewTab: ((String) -> Void)? = nil
    @Environment(\.bkPalette) private var palette

    @State private var showingSettingsSheet = false
    @State private var bookmarkToEdit: BookmarkItem? = nil
    @State private var showingAddBookmarkSheet = false
    @State private var addBookmarkInitialCategoryID: UUID? = nil
    @State private var showingAddCategorySheet = false
    @State private var categoryToRename: BookmarkCategory? = nil
    @State private var categoryToDelete: BookmarkCategory? = nil
    @State private var showingNameUncategorizedSheet = false
    @State private var shareSheetMode: ShareCodeSheetMode? = nil

    // Category header drag-reorder state
    @State private var draggingCategory: BookmarkCategory? = nil
    @State private var categoryDropIndex: Int? = nil

    // Drag and drop preview states
    @State private var draggingBookmark: BookmarkItem? = nil
    @State private var dragCurrentLocation: CGPoint = .zero
    @State private var dropTarget: BookmarkDropTarget? = nil
    @State private var itemGeometries: [BookmarkItemGeometry] = []
    @State private var sectionGeometries: [CategorySectionGeometry] = []

    private let coordinateSpaceName = "BrowserHomeBookmarkCoordinateSpace"

    private func bookmarks(for categoryID: UUID?) -> [BookmarkItem] {
        preferences.bookmarks.filter { $0.categoryID == categoryID }
    }

    private func canMoveBookmark(_ item: BookmarkItem, by offset: Int) -> Bool {
        let items = bookmarks(for: item.categoryID)
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return false }
        return items.indices.contains(idx + offset)
    }

    private func moveBookmark(_ item: BookmarkItem, by offset: Int) {
        let items = bookmarks(for: item.categoryID)
        guard let currentIdx = items.firstIndex(where: { $0.id == item.id }),
              items.indices.contains(currentIdx + offset) else { return }
        let targetIndex = currentIdx + offset
        preferences.moveBookmark(id: item.id, toCategory: item.categoryID, atCategoryIndex: targetIndex)
    }

    private func updateDropTarget(for location: CGPoint) {
        guard let dragging = draggingBookmark else {
            dropTarget = nil
            return
        }

        // 1. Check if location falls inside or near any category section
        for section in sectionGeometries {
            // Expand hit area slightly vertically
            let hitRect = section.frame.insetBy(dx: -10, dy: -6)
            if hitRect.contains(location) {
                let itemsInSection = itemGeometries.filter { $0.categoryID == section.categoryID }
                if itemsInSection.isEmpty {
                    dropTarget = BookmarkDropTarget(categoryID: section.categoryID, index: 0)
                    return
                }

                // Check distance to items in section
                var bestIndex = 0
                var minDistance = CGFloat.greatestFiniteMagnitude

                for itemGeo in itemsInSection {
                    let leadingEdge = CGPoint(x: itemGeo.frame.minX, y: itemGeo.frame.midY)
                    let trailingEdge = CGPoint(x: itemGeo.frame.maxX, y: itemGeo.frame.midY)

                    let distLeading = hypot(location.x - leadingEdge.x, location.y - leadingEdge.y)
                    let distTrailing = hypot(location.x - trailingEdge.x, location.y - trailingEdge.y)

                    if distLeading < minDistance {
                        minDistance = distLeading
                        bestIndex = itemGeo.index
                    }
                    if distTrailing < minDistance {
                        minDistance = distTrailing
                        bestIndex = itemGeo.index + 1
                    }
                }

                dropTarget = BookmarkDropTarget(categoryID: section.categoryID, index: bestIndex)
                return
            }
        }

        // If outside all sections, cancel preview
        dropTarget = nil
    }

    private func commitDrop() {
        guard let dragging = draggingBookmark, let target = dropTarget else {
            draggingBookmark = nil
            dropTarget = nil
            return
        }

        let finalIndex: Int
        if dragging.categoryID == target.categoryID,
           let sourceIndex = bookmarks(for: dragging.categoryID).firstIndex(where: { $0.id == dragging.id }),
           sourceIndex < target.index {
            finalIndex = target.index - 1
        } else {
            finalIndex = target.index
        }

        // Atomic commit on drop
        preferences.moveBookmark(id: dragging.id, toCategory: target.categoryID, atCategoryIndex: finalIndex)

        draggingBookmark = nil
        dropTarget = nil
    }

    /// Insertion slot (0...categories.count) among named categories for a pointer location.
    private func categoryInsertionIndex(for location: CGPoint) -> Int {
        var index = 0
        for cat in preferences.categories {
            guard let frame = sectionGeometries.first(where: { $0.categoryID == cat.id })?.frame else { continue }
            if location.y > frame.midY { index += 1 }
        }
        return index
    }

    private func commitCategoryDrop() {
        defer {
            draggingCategory = nil
            categoryDropIndex = nil
        }
        guard let dragging = draggingCategory,
              let slot = categoryDropIndex,
              let from = preferences.categories.firstIndex(where: { $0.id == dragging.id }) else { return }
        // Slot is an insertion position in the pre-removal list; moveCategory(toIndex:) expects the final index.
        let final = from < slot ? slot - 1 : slot
        preferences.moveCategory(id: dragging.id, toIndex: final)
    }

    private func openAllBookmarks(in items: [BookmarkItem], categoryTitle: String) {
        let snapshot = items
        guard !snapshot.isEmpty else { return }

        var skippedInvalid = 0
        for item in snapshot {
            guard let validURL = BrowserPreferences.validateWebURL(item.url) else {
                skippedInvalid += 1
                continue
            }
            if let onOpenNewTab = onOpenNewTab {
                onOpenNewTab(validURL)
            } else if let tab = appModel.newTab() {
                tab.open(validURL)
            }
        }

        if skippedInvalid > 0 {
            appModel.setDropFeedback("\(categoryTitle)의 즐겨찾기 중 올바르지 않은 주소 \(skippedInvalid)개를 건너뛰었습니다.")
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                startPageSettingsCard
                bookmarksVerticalSections
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(BookmarkItemGeometryPreferenceKey.self) { geometries in
            self.itemGeometries = geometries
        }
        .onPreferenceChange(CategorySectionGeometryPreferenceKey.self) { sections in
            self.sectionGeometries = sections
        }
        .overlay(
            Group {
                if let dragging = draggingBookmark {
                    dragFloatingPreview(item: dragging)
                }
                if let dragging = draggingCategory {
                    categoryFloatingPreview(name: dragging.name)
                }
            }
        )
        .sheet(isPresented: $showingSettingsSheet) {
            BrowserHomeSettingsSheet(preferences: preferences, model: model) {
                showingSettingsSheet = false
            }
            .byungkiThemed(palette)
        }
        .sheet(item: $bookmarkToEdit) { item in
            EditBookmarkSheet(
                bookmark: item,
                categories: preferences.categories,
                onSave: { newTitle, newURL, newCategoryID in
                    let result = preferences.updateBookmark(id: item.id, title: newTitle, url: newURL, categoryID: newCategoryID)
                    if result.success {
                        BookmarkAppearanceManager.shared.loadIfNeeded(for: newURL)
                        bookmarkToEdit = nil
                        return (true, nil)
                    } else {
                        return (false, result.error ?? preferences.errorMessage ?? "즐겨찾기를 저장하지 못했습니다.")
                    }
                },
                onCancel: {
                    bookmarkToEdit = nil
                }
            )
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingAddBookmarkSheet) {
            AddBookmarkSheet(categories: preferences.categories, initialCategoryID: addBookmarkInitialCategoryID, onAdd: { url, title, catID in
                if preferences.addBookmark(url: url, title: title, categoryID: catID) {
                    showingAddBookmarkSheet = false
                    return (true, nil)
                } else {
                    return (false, preferences.errorMessage ?? "유효한 http/https 주소를 입력해 주세요.")
                }
            }, onCancel: {
                showingAddBookmarkSheet = false
            })
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingAddCategorySheet) {
            AddCategorySheet(onAdd: { name in
                if preferences.addCategory(name: name) != nil {
                    showingAddCategorySheet = false
                    return (true, nil)
                } else {
                    return (false, preferences.errorMessage ?? "카테고리 이름을 확인해 주세요.")
                }
            }, onCancel: {
                showingAddCategorySheet = false
            })
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingNameUncategorizedSheet) {
            AddCategorySheet(
                title: "미분류 이름 지정",
                message: "현재 '미분류'에 있는 모든 즐겨찾기를 새 카테고리로 옮깁니다. 순서와 정보는 그대로 유지되며, 비어 있는 '미분류'는 다시 만들어집니다.",
                confirmTitle: "이름 지정",
                onAdd: { name in
                    if preferences.nameUncategorized(as: name) != nil {
                        showingNameUncategorizedSheet = false
                        return (true, nil)
                    } else {
                        return (false, preferences.errorMessage ?? "카테고리 이름을 확인해 주세요.")
                    }
                },
                onCancel: { showingNameUncategorizedSheet = false }
            )
            .byungkiThemed(palette)
        }
        .sheet(item: $shareSheetMode) { mode in
            ShareCodeSheet(
                mode: mode,
                makeCode: { try preferences.exportShareCode() },
                onImport: { code in try preferences.importShareCode(code) },
                onClose: { shareSheetMode = nil }
            )
            .byungkiThemed(palette)
        }
        .sheet(item: $categoryToRename) { cat in
            CategoryRenameSheet(category: cat, onSave: { newName in
                if preferences.renameCategory(id: cat.id, newName: newName) {
                    categoryToRename = nil
                    return (true, nil)
                } else {
                    return (false, preferences.errorMessage ?? "카테고리 이름을 확인해 주세요.")
                }
            }, onCancel: {
                categoryToRename = nil
            })
            .byungkiThemed(palette)
        }
        .alert(
            "카테고리 삭제",
            isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }
            ),
            presenting: categoryToDelete
        ) { cat in
            Button("삭제", role: .destructive) {
                preferences.removeCategory(id: cat.id)
                categoryToDelete = nil
            }
            Button("취소", role: .cancel) {
                categoryToDelete = nil
            }
        } message: { cat in
            Text("'\(cat.name)' 카테고리를 삭제하시겠습니까?\n카테고리에 속한 즐겨찾기는 삭제되지 않으며 '미분류'로 이동합니다.")
        }
    }

    private func dragFloatingPreview(item: BookmarkItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .foregroundColor(palette.accentColor)
                .font(.caption)
            Text(item.title)
                .font(.caption.bold())
                .foregroundColor(palette.textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.surfaceColor)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.accentColor, lineWidth: 1.5)
        )
        .position(dragCurrentLocation)
        .allowsHitTesting(false)
    }

    private func categoryFloatingPreview(name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundColor(palette.accentColor)
                .font(.caption)
            Text(name)
                .font(.caption.bold())
                .foregroundColor(palette.textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.surfaceColor)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.accentColor, lineWidth: 1.5))
        .position(dragCurrentLocation)
        .allowsHitTesting(false)
    }

    private var categoryInsertionBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(palette.accentColor)
            .frame(height: 4)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private var bookmarksVerticalSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Label("즐겨찾기", systemImage: "bookmark.fill")
                    .font(.headline)
                    .foregroundColor(palette.textColor)

                if !preferences.bookmarks.isEmpty {
                    Text("\(preferences.bookmarks.count)")
                        .font(.caption.bold())
                        .foregroundColor(palette.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(palette.accentSoftColor))
                }

                Spacer()

                Menu("공유") {
                    Button("즐겨찾기 내보내기 (.httbookmarks)…") { exportBookmarks(format: .httbookmarks) }
                    Button("레거시 Markdown으로 내보내기 (.md)…") { exportBookmarks(format: .markdown) }
                    Divider()
                    Button("즐겨찾기 가져오기…") { importBookmarks() }
                    Divider()
                    Button("HTD 공유 코드 만들기…") { shareSheetMode = .export }
                    Button("HTD 공유 코드로 가져오기…") { shareSheetMode = .importCode }
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    showingAddCategorySheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                        Text("분류 추가")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("새 즐겨찾기 카테고리 추가")
                .accessibilityLabel("새 카테고리 추가")

                Button {
                    addBookmarkInitialCategoryID = nil
                    showingAddBookmarkSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("즐겨찾기 추가")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("새 즐겨찾기 주소 추가")
                .accessibilityLabel("새 즐겨찾기 추가")
            }

            // Vertical list of category sections (reserved uncategorized first, only when non-empty, then persisted categories)
            VStack(spacing: 20) {
                if !bookmarks(for: nil).isEmpty {
                    categorySectionView(
                        categoryID: nil,
                        title: "미분류",
                        icon: "tray.fill",
                        canMoveUp: false,
                        canMoveDown: false,
                        onMoveUp: nil,
                        onMoveDown: nil,
                        onRename: nil,
                        onDelete: nil
                    )
                }

                ForEach(Array(preferences.categories.enumerated()), id: \.element.id) { catIndex, cat in
                    if categoryDropIndex == catIndex, draggingCategory != nil {
                        categoryInsertionBar
                    }
                    categorySectionView(
                        categoryID: cat.id,
                        title: cat.name,
                        icon: "folder.fill",
                        canMoveUp: preferences.canMoveCategory(id: cat.id, by: -1),
                        canMoveDown: preferences.canMoveCategory(id: cat.id, by: 1),
                        onMoveUp: { preferences.moveCategory(id: cat.id, by: -1) },
                        onMoveDown: { preferences.moveCategory(id: cat.id, by: 1) },
                        onRename: { categoryToRename = cat },
                        onDelete: { categoryToDelete = cat }
                    )
                    .opacity(draggingCategory?.id == cat.id ? 0.45 : 1.0)
                    if categoryDropIndex == preferences.categories.count,
                       catIndex == preferences.categories.count - 1,
                       draggingCategory != nil {
                        categoryInsertionBar
                    }
                }
            }
        }
    }

    private func categorySectionView(
        categoryID: UUID?,
        title: String,
        icon: String,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onMoveUp: (() -> Void)?,
        onMoveDown: (() -> Void)?,
        onRename: (() -> Void)?,
        onDelete: (() -> Void)?
    ) -> some View {
        let items = bookmarks(for: categoryID)
        let isSectionTargeted = dropTarget?.categoryID == categoryID

        return VStack(alignment: .leading, spacing: 10) {
            // Category Header
            HStack(spacing: 8) {
                if let draggedCat = preferences.categories.first(where: { $0.id == categoryID }) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedColor)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
                                .onChanged { value in
                                    if draggingCategory == nil { draggingCategory = draggedCat }
                                    dragCurrentLocation = value.location
                                    categoryDropIndex = categoryInsertionIndex(for: value.location)
                                }
                                .onEnded { value in
                                    categoryDropIndex = categoryInsertionIndex(for: value.location)
                                    commitCategoryDrop()
                                }
                        )
                        .help("드래그하여 카테고리 순서 변경")
                        .accessibilityLabel("\(title) 카테고리 순서 변경 핸들")
                }

                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundColor(palette.accentColor)

                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(palette.textColor)

                Button {
                    openAllBookmarks(in: items, categoryTitle: title)
                } label: {
                    Text("\(items.count)")
                        .font(.caption2.bold())
                        .foregroundColor(palette.mutedColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(palette.surfaceColor))
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .help("\(title)의 즐겨찾기 \(items.count)개 모두 새 탭으로 열기")
                .accessibilityLabel("\(title) 즐겨찾기 \(items.count)개 모두 새 탭으로 열기")

                Spacer()

                if categoryID == nil && !items.isEmpty {
                    Button("이름 지정") { showingNameUncategorizedSheet = true }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("미분류 즐겨찾기 전체를 새 카테고리로 묶기")
                        .accessibilityLabel("미분류 즐겨찾기에 카테고리 이름 지정")
                }

                if let onMoveUp = onMoveUp, let onMoveDown = onMoveDown {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                    .help("카테고리 위로 이동")

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                    .help("카테고리 아래로 이동")
                }

                Button {
                    addBookmarkInitialCategoryID = categoryID
                    showingAddBookmarkSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("\(title)에 즐겨찾기 추가")

                if onRename != nil || onDelete != nil {
                    Menu {
                        if let onRename = onRename {
                            Button("이름 변경", action: onRename)
                        }
                        if let onMoveUp = onMoveUp {
                            Button("위로 이동", action: onMoveUp).disabled(!canMoveUp)
                        }
                        if let onMoveDown = onMoveDown {
                            Button("아래로 이동", action: onMoveDown).disabled(!canMoveDown)
                        }
                        if let onDelete = onDelete {
                            Divider()
                            Button("카테고리 삭제", role: .destructive, action: onDelete)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundColor(palette.mutedColor)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 4)

            // Category Content (Grid with items + insertion previews, or empty state)
            ZStack(alignment: .leading) {
                if items.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text(isSectionTargeted ? "여기에 놓아 즐겨찾기를 이동합니다" : "즐겨찾기가 없습니다")
                                .font(.caption)
                                .foregroundColor(isSectionTargeted ? palette.accentColor : palette.mutedColor)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSectionTargeted ? palette.accentColor : palette.borderColor.opacity(0.6),
                                style: StrokeStyle(lineWidth: isSectionTargeted ? 1.5 : 1, dash: [4, 4])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSectionTargeted ? palette.accentSoftColor.opacity(0.5) : Color.clear)
                            )
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let isCurrentTarget = dropTarget?.categoryID == categoryID && dropTarget?.index == index
                            let isTrailingTarget = dropTarget?.categoryID == categoryID && dropTarget?.index == items.count && index == items.count - 1

                            HStack(spacing: 0) {
                                // Insertion indicator line at leading edge if targeted here
                                if isCurrentTarget {
                                    insertionLine
                                }

                                BookmarkTileView(
                                    item: item,
                                    categories: preferences.categories,
                                    coordinateSpaceName: coordinateSpaceName,
                                    isDraggingSelf: draggingBookmark?.id == item.id,
                                    onOpen: {
                                        model.open(item.url)
                                    },
                                    onEdit: {
                                        bookmarkToEdit = item
                                    },
                                    onDelete: {
                                        preferences.removeBookmark(id: item.id)
                                    },
                                    canMoveUp: canMoveBookmark(item, by: -1),
                                    canMoveDown: canMoveBookmark(item, by: 1),
                                    onMoveUp: { moveBookmark(item, by: -1) },
                                    onMoveDown: { moveBookmark(item, by: 1) },
                                    onAssignCategory: { catID in
                                        preferences.assignBookmark(id: item.id, categoryID: catID)
                                    },
                                    onDragChanged: { loc in
                                        if draggingBookmark == nil {
                                            draggingBookmark = item
                                        }
                                        dragCurrentLocation = loc
                                        updateDropTarget(for: loc)
                                    },
                                    onDragEnded: { loc in
                                        updateDropTarget(for: loc)
                                        commitDrop()
                                    }
                                )
                                .background(
                                    GeometryReader { itemGeo in
                                        Color.clear.preference(
                                            key: BookmarkItemGeometryPreferenceKey.self,
                                            value: [
                                                BookmarkItemGeometry(
                                                    id: item.id,
                                                    categoryID: categoryID,
                                                    index: index,
                                                    frame: itemGeo.frame(in: .named(coordinateSpaceName))
                                                )
                                            ]
                                        )
                                    }
                                )

                                if isTrailingTarget {
                                    insertionLine
                                }
                            }
                        }
                    }
                }
            }
            .background(
                GeometryReader { secGeo in
                    Color.clear.preference(
                        key: CategorySectionGeometryPreferenceKey.self,
                        value: [
                            CategorySectionGeometry(
                                categoryID: categoryID,
                                frame: secGeo.frame(in: .named(coordinateSpaceName)),
                                count: items.count
                            )
                        ]
                    )
                }
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.surfaceColor.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSectionTargeted ? palette.accentColor : palette.borderColor.opacity(0.7), lineWidth: isSectionTargeted ? 1.5 : 1)
        )
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(palette.accentColor)
            .frame(width: 4)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .animation(.easeInOut(duration: 0.15), value: dropTarget)
    }

    private var startPageSettingsCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("시작 페이지")
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
                Text(startPageSummary)
                    .font(.caption2)
                    .foregroundColor(palette.mutedColor)
                    .lineLimit(1)
            }
            Spacer()
            Button("시작 페이지 설정...") {
                showingSettingsSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("시작 페이지 설정 변경")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderColor, lineWidth: 1))
    }

    private var startPageSummary: String {
        switch preferences.startPageMode {
        case .builtInHome:
            return "기본 시작 화면 (즐겨찾기 목록)"
        case .customURL:
            return preferences.customHomeURL.isEmpty ? "사용자 지정 시작 주소" : preferences.customHomeURL
        }
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onDropBookmark: ((UUID) -> Void)?
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(\.bkPalette) private var palette
    @State private var isTargeted = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.bold())
                Text("\(count)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? palette.onAccentColor : palette.surfaceColor)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isSelected ? palette.accentColor : (isTargeted ? palette.accentSoftColor : palette.surfaceColor)
                )
            )
            .foregroundColor(isSelected ? palette.onAccentColor : palette.textColor)
            .overlay(
                Capsule()
                    .stroke(
                        isTargeted ? palette.accentColor : (isSelected ? palette.accentColor : palette.borderColor),
                        lineWidth: isTargeted ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRename = onRename {
                Button("이름 변경", action: onRename)
            }
            if let onDelete = onDelete {
                Divider()
                Button("카테고리 삭제", role: .destructive, action: onDelete)
            }
        }
        .onDrop(of: [BookmarkTileView.dragTypeID], isTargeted: $isTargeted) { providers in
            guard let onDropBookmark = onDropBookmark else { return false }
            guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(BookmarkTileView.dragTypeID) }) else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: BookmarkTileView.dragTypeID) { data, _ in
                guard let data, data.count <= 64,
                      let text = String(data: data, encoding: .utf8),
                      let id = UUID(uuidString: text) else { return }
                DispatchQueue.main.async {
                    onDropBookmark(id)
                }
            }
            return true
        }
    }
}

// MARK: - Bookmark Tile

struct BookmarkTileView: View {
    let item: BookmarkItem
    let categories: [BookmarkCategory]
    var coordinateSpaceName: String = "BrowserHomeBookmarkCoordinateSpace"
    var isDraggingSelf: Bool = false
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    var onDropBookmark: ((UUID) -> Void)? = nil
    let onAssignCategory: (UUID?) -> Void
    var onDragChanged: ((CGPoint) -> Void)? = nil
    var onDragEnded: ((CGPoint) -> Void)? = nil

    @Environment(\.bkPalette) private var palette
    @ObservedObject private var appearanceManager = BookmarkAppearanceManager.shared
    @State private var isHovering = false
    @State private var isHandleDragging = false

    /// Private drag type: carries only the bookmark id (no URL/text/file), so a drop elsewhere cannot start a download.
    static let dragTypeID = UTType(exportedAs: "com.hanstree.HttpsDown.bookmark-id", conformingTo: .data).identifier

    @ViewBuilder private var orderButtons: some View {
        Button("위로 이동", action: onMoveUp).disabled(!canMoveUp)
        Button("아래로 이동", action: onMoveDown).disabled(!canMoveDown)
    }

    @ViewBuilder private var categoryMenu: some View {
        Menu("카테고리") {
            Button {
                onAssignCategory(nil)
            } label: {
                if item.categoryID == nil {
                    Label("미분류", systemImage: "checkmark")
                } else {
                    Text("미분류")
                }
            }
            if !categories.isEmpty {
                Divider()
                ForEach(categories) { cat in
                    Button {
                        onAssignCategory(cat.id)
                    } label: {
                        if item.categoryID == cat.id {
                            Label(cat.name, systemImage: "checkmark")
                        } else {
                            Text(cat.name)
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        let appearance = appearanceManager.appearance(for: item.url)
        let siteColor = appearance?.siteColor

        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    if let fav = appearance?.favicon {
                        Image(nsImage: fav)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(siteColor?.opacity(0.18) ?? palette.accentSoftColor))
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 16))
                            .foregroundColor(palette.accentColor)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(palette.accentSoftColor))
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.caption.bold())
                            .foregroundColor(palette.textColor)
                            .lineLimit(1)

                        Text(item.host)
                            .font(.caption2)
                            .foregroundColor(palette.mutedColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 50)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("즐겨찾기: \(item.title), \(item.host)")
            .accessibilityAction(named: "열기", onOpen)

            HStack(spacing: 2) {
                // Drag handle with SwiftUI DragGesture in named coordinate space
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundColor((isHovering || isHandleDragging) ? palette.mutedColor : palette.mutedColor.opacity(0.35))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .gesture(
                        DragGesture(coordinateSpace: .named(coordinateSpaceName))
                            .onChanged { value in
                                isHandleDragging = true
                                onDragChanged?(value.location)
                            }
                            .onEnded { value in
                                isHandleDragging = false
                                onDragEnded?(value.location)
                            }
                    )
                    .help("드래그하여 순서 및 카테고리 변경")
                    .accessibilityLabel("드래그하여 순서 및 카테고리 변경")

                Menu {
                    Button("열기", action: onOpen)
                    Button("즐겨찾기 편집", action: onEdit)
                    orderButtons
                    Divider()
                    categoryMenu
                    Divider()
                    Button("삭제", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundColor(palette.mutedColor)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
                .help("즐겨찾기 옵션")
                .accessibilityLabel("\(item.title) 즐겨찾기 메뉴")
            }
            .padding(10)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isDraggingSelf ? 0.35 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(siteColor?.opacity(0.12) ?? Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    (isHovering || isHandleDragging) ? palette.accentColor : (siteColor?.opacity(0.35) ?? palette.borderColor),
                    lineWidth: 1
                )
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("열기", action: onOpen)
            Button("즐겨찾기 편집", action: onEdit)
            orderButtons
            Divider()
            categoryMenu
            Divider()
            Button("삭제", role: .destructive, action: onDelete)
        }
        .task(id: item.url) {
            appearanceManager.loadIfNeeded(for: item.url)
        }
    }
}

// MARK: - Bookmark Appearance Manager (Favicon & Representative Color)

@MainActor
final class BookmarkAppearanceManager: ObservableObject {
    static let shared = BookmarkAppearanceManager()

    struct Appearance {
        var favicon: NSImage?
        var siteColor: Color?
    }

    @Published private(set) var appearances: [String: Appearance] = [:]
    private var inFlight: [String: Task<Appearance, Never>] = [:]
    /// In-session time of the last refresh attempt per site, so an expired entry is retried at most once per negativeTTL.
    private var lastRefreshAttempt: [String: TimeInterval] = [:]

    // MARK: Persistent cache (derived icon/color only, keyed by normalized origin)

    /// File name inside the app configuration's store directory.
    nonisolated static let cacheFileName = "bookmark-appearance-cache.json"
    /// A site with a decoded favicon is trusted for 14 days.
    nonisolated private static let positiveTTL: TimeInterval = 14 * 24 * 3600
    /// A fetch that found no favicon (offline, error, none published) is retried after 2 hours, never kept longer.
    nonisolated private static let negativeTTL: TimeInterval = 2 * 3600
    nonisolated private static let maxEntries = 128
    nonisolated private static let maxIconBytes = 16 * 1024
    nonisolated private static let maxFileBytes = 4 * 1024 * 1024
    nonisolated private static let persistQueue = DispatchQueue(label: "com.hanstree.HttpsDown.bookmark-appearance-cache", qos: .utility)

    private struct StoredEntry: Codable {
        var key: String
        var fetchedAt: TimeInterval
        /// Re-encoded PNG of the already downscaled (<= 64 px) favicon; never the original download.
        var icon: Data?
        /// sRGB red, green, blue in 0...1.
        var rgb: [Double]?
    }

    private struct StoredCache: Codable {
        var version: Int
        var entries: [StoredEntry]
    }

    private var records: [String: StoredEntry] = [:]
    private var persistenceURL: URL?
    /// Incremented by cleanup and by a changed cache location: results of fetches started under an older value are dropped.
    private var generation = 0

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        self.session = URLSession(configuration: config)
    }

    /// Points the cache at the current configuration's file and loads the still-fresh entries from it.
    func configurePersistence(fileURL: URL) {
        if persistenceURL == fileURL { return }
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        lastRefreshAttempt.removeAll()
        appearances.removeAll()
        records.removeAll()
        persistenceURL = fileURL
        loadPersisted(from: fileURL)
    }

    /// Cleanup: forgets everything in memory and on disk, cancels running fetches and invalidates their results.
    /// Returns how many sites had a cached appearance.
    @discardableResult
    func clearCachedAppearances() -> Int {
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        lastRefreshAttempt.removeAll()
        let count = appearances.count
        appearances.removeAll()
        records.removeAll()
        if let url = persistenceURL {
            // Same serial queue as saves: a save queued before this point runs first, a later one carries newer data.
            Self.persistQueue.async { try? FileManager.default.removeItem(at: url) }
        }
        return count
    }

    private func loadPersisted(from url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 0, size.intValue <= Self.maxFileBytes,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredCache.self, from: data),
              stored.version == 1 else { return }

        let now = Date().timeIntervalSince1970
        let fresh = stored.entries.sorted { $0.fetchedAt > $1.fetchedAt }
        for entry in fresh {
            if records.count >= Self.maxEntries { break }
            guard originKey(for: entry.key) == entry.key, records[entry.key] == nil else { continue }
            let age = now - entry.fetchedAt
            guard age >= -300 else { continue }

            var favicon: NSImage? = nil
            if let icon = entry.icon, icon.count <= Self.maxIconBytes {
                favicon = Self.decodeThumbnailSafely(from: icon)
            }
            guard age <= (favicon != nil ? Self.positiveTTL : Self.negativeTTL) else { continue }

            var color: Color? = nil
            if let c = entry.rgb, c.count == 3, c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
                color = Color(red: c[0], green: c[1], blue: c[2])
            }
            appearances[entry.key] = Appearance(favicon: favicon, siteColor: color)
            records[entry.key] = StoredEntry(key: entry.key, fetchedAt: entry.fetchedAt,
                                             icon: favicon != nil ? entry.icon : nil, rgb: color != nil ? entry.rgb : nil)
        }
    }

    private func record(_ appearance: Appearance, forKey key: String) {
        var rgb: [Double]? = nil
        if let color = appearance.siteColor, let c = NSColor(color).usingColorSpace(.sRGB) {
            rgb = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        }
        var icon: Data? = nil
        if let image = appearance.favicon,
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
           png.count <= Self.maxIconBytes {
            icon = png
        }
        records[key] = StoredEntry(key: key, fetchedAt: Date().timeIntervalSince1970, icon: icon, rgb: rgb)
        if records.count > Self.maxEntries {
            let overflow = records.values.sorted { $0.fetchedAt < $1.fetchedAt }.prefix(records.count - Self.maxEntries)
            for old in overflow { records.removeValue(forKey: old.key) }
        }
        savePersisted()
    }

    private func savePersisted() {
        guard let url = persistenceURL else { return }
        let snapshot = StoredCache(version: 1, entries: Array(records.values))
        Self.persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func appearance(for urlString: String) -> Appearance? {
        guard let key = originKey(for: urlString) else { return nil }
        return appearances[key]
    }

    func loadIfNeeded(for urlString: String) {
        guard let key = originKey(for: urlString) else { return }
        if inFlight[key] != nil { return }
        let now = Date().timeIntervalSince1970
        if let existing = appearances[key] {
            // Keep showing the cached result; refresh once its TTL has passed, at most once per negativeTTL.
            guard let rec = records[key],
                  now - rec.fetchedAt > (existing.favicon != nil ? Self.positiveTTL : Self.negativeTTL),
                  now - (lastRefreshAttempt[key] ?? 0) > Self.negativeTTL else { return }
        }
        lastRefreshAttempt[key] = now

        let startedGeneration = generation
        let task = Task { [weak self, session] () -> Appearance in
            let res = await Self.fetchAppearance(originKey: key, session: session)
            await MainActor.run { [weak self] in
                guard let self = self, self.generation == startedGeneration else { return }
                self.inFlight.removeValue(forKey: key)
                // A failed refresh must not replace (or re-stamp) a previous successful entry.
                if res.favicon == nil, let old = self.appearances[key], old.favicon != nil { return }
                self.appearances[key] = res
                self.record(res, forKey: key)
            }
            return res
        }
        inFlight[key] = task
    }

    private func originKey(for urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil else { return nil }

        let lowerHost = host.lowercased()
        let portPart: String
        if let port = comps.port {
            if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
                portPart = ""
            } else {
                portPart = ":\(port)"
            }
        } else {
            portPart = ""
        }

        let formattedHost = lowerHost.contains(":") && !lowerHost.hasPrefix("[") ? "[\(lowerHost)]" : lowerHost
        return "\(scheme)://\(formattedHost)\(portPart)"
    }

    private final class StrictSameOriginDelegate: NSObject, URLSessionTaskDelegate {
        let expectedOrigin: (scheme: String, host: String, effectivePort: Int)

        init(expectedOrigin: (scheme: String, host: String, effectivePort: Int)) {
            self.expectedOrigin = expectedOrigin
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let newURL = request.url,
                  BookmarkAppearanceManager.isSameOrigin(newURL, matching: expectedOrigin) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    nonisolated private static func effectiveOrigin(for url: URL) -> (scheme: String, host: String, effectivePort: Int)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil else { return nil }

        let effectivePort: Int
        if let p = comps.port {
            effectivePort = p
        } else if scheme == "http" {
            effectivePort = 80
        } else if scheme == "https" {
            effectivePort = 443
        } else {
            return nil
        }
        return (scheme, host.lowercased(), effectivePort)
    }

    nonisolated private static func isSameOrigin(_ url: URL, matching expected: (scheme: String, host: String, effectivePort: Int)) -> Bool {
        guard let actual = effectiveOrigin(for: url) else { return false }
        return actual.scheme == expected.scheme &&
               actual.host == expected.host &&
               actual.effectivePort == expected.effectivePort
    }

    private static func readBoundedBytes(
        from url: URL,
        session: URLSession,
        maxBytes: Int,
        stopAtHeadClosing: Bool,
        expectedOrigin: (scheme: String, host: String, effectivePort: Int)
    ) async -> Data? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4.0
        if stopAtHeadClosing {
            req.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
            req.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }

        let delegate = StrictSameOriginDelegate(expectedOrigin: expectedOrigin)
        guard let (bytes, response) = try? await session.bytes(for: req, delegate: delegate) else {
            return nil
        }
        defer {
            bytes.task.cancel()
        }

        guard let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) || (stopAtHeadClosing && httpResp.statusCode == 206),
              let respURL = httpResp.url,
              isSameOrigin(respURL, matching: expectedOrigin) else {
            return nil
        }

        if !stopAtHeadClosing,
           let lengthHeader = httpResp.value(forHTTPHeaderField: "Content-Length"),
           let declaredLength = Int(lengthHeader), declaredLength > maxBytes {
            return nil
        }

        var buffer = Data()
        buffer.reserveCapacity(min(maxBytes, 4096))

        do {
            for try await byte in bytes {
                if buffer.count >= maxBytes {
                    if stopAtHeadClosing {
                        break
                    } else {
                        return nil
                    }
                }
                buffer.append(byte)

                if stopAtHeadClosing && buffer.count >= 7 {
                    let tailWindow = buffer.suffix(16)
                    if let tailStr = String(data: tailWindow, encoding: .ascii)?.lowercased(),
                       tailStr.contains("</head>") {
                        break
                    }
                }
            }
        } catch {
            return nil
        }

        return buffer
    }

    private static func decodeThumbnailSafely(from data: Data) -> NSImage? {
        guard data.count >= 4 else { return nil }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let scanLimit = min(count, 32)
        var selectedValidatedIndex: Int? = nil

        for idx in 0..<scanLimit {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, idx, nil) as? [CFString: Any] else {
                continue
            }
            if let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                let w = pixelWidth.intValue
                let h = pixelHeight.intValue
                if w >= 8 && w <= 1024 && h >= 8 && h <= 1024 && (w * h) <= 1_048_576 {
                    selectedValidatedIndex = idx
                    break
                }
            }
        }

        guard let targetIndex = selectedValidatedIndex else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, targetIndex, thumbOptions as CFDictionary) else {
            return nil
        }

        let size = NSSize(width: cgThumb.width, height: cgThumb.height)
        guard size.width >= 8 && size.height >= 8 else { return nil }

        return NSImage(cgImage: cgThumb, size: size)
    }

    private static func fetchAppearance(originKey: String, session: URLSession) async -> Appearance {
        guard let rootURL = URL(string: originKey + "/"),
              let rootOrigin = effectiveOrigin(for: rootURL) else {
            return Appearance(favicon: nil, siteColor: nil)
        }

        var themeColor: Color? = nil
        var iconRelativePath: String? = nil

        if let htmlData = await readBoundedBytes(
            from: rootURL,
            session: session,
            maxBytes: 32768,
            stopAtHeadClosing: true,
            expectedOrigin: rootOrigin
        ) {
            let boundedData = htmlData.prefix(32768)
            if let html = String(data: boundedData, encoding: .utf8) ?? String(data: boundedData, encoding: .ascii) {
                let headPortion: String
                if let headEndRange = html.range(of: "</head>", options: .caseInsensitive) {
                    headPortion = String(html[..<headEndRange.upperBound])
                } else {
                    headPortion = html
                }
                themeColor = parseThemeColor(from: headPortion)
                iconRelativePath = parseIconLink(from: headPortion)
            }
        }

        var targetIconURL: URL? = nil
        if let iconRel = iconRelativePath,
           let resolved = URL(string: iconRel, relativeTo: rootURL)?.absoluteURL,
           isSameOrigin(resolved, matching: rootOrigin) {
            targetIconURL = resolved
        } else if let fallback = URL(string: "/favicon.ico", relativeTo: rootURL)?.absoluteURL,
                  isSameOrigin(fallback, matching: rootOrigin) {
            targetIconURL = fallback
        }

        var fetchedFavicon: NSImage? = nil
        if let iconURL = targetIconURL {
            if let iconData = await readBoundedBytes(
                from: iconURL,
                session: session,
                maxBytes: 256 * 1024,
                stopAtHeadClosing: false,
                expectedOrigin: rootOrigin
            ) {
                fetchedFavicon = decodeThumbnailSafely(from: iconData)
            }
        }

        let finalColor: Color?
        if let tc = themeColor {
            finalColor = tc
        } else if let img = fetchedFavicon {
            finalColor = deriveRepresentativeColor(from: img)
        } else {
            finalColor = nil
        }

        return Appearance(favicon: fetchedFavicon, siteColor: finalColor)
    }

    private static func parseThemeColor(from html: String) -> Color? {
        let pattern = "<meta[^>]+name=[\"']theme-color[\"'][^>]*content=[\"']([^\"']+)[\"']|<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*name=[\"']theme-color[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range) else { return nil }
        for i in 1...2 {
            let r = match.range(at: i)
            if r.location != NSNotFound, let strRange = Range(r, in: html) {
                let val = String(html[strRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let c = parseHexColor(val) ?? parseRgbColor(val) {
                    return c
                }
            }
        }
        return nil
    }

    private static func parseIconLink(from html: String) -> String? {
        let pattern = "<link[^>]+rel=[\"'](?:shortcut icon|icon|apple-touch-icon)[\"'][^>]*href=[\"']([^\"']+)[\"']|<link[^>]+href=[\"']([^\"']+)[\"'][^>]*rel=[\"'](?:shortcut icon|icon|apple-touch-icon)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range) else { return nil }
        for i in 1...2 {
            let r = match.range(at: i)
            if r.location != NSNotFound, let strRange = Range(r, in: html) {
                let val = String(html[strRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    private static func parseHexColor(_ raw: String) -> Color? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6 else { return nil }
        let fullHex: String
        if hex.count == 3 {
            fullHex = hex.map { "\($0)\($0)" }.joined()
        } else {
            fullHex = hex
        }
        guard let val = UInt64(fullHex, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    private static func parseRgbColor(_ raw: String) -> Color? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("rgb(") && trimmed.hasSuffix(")") else { return nil }
        let inner = trimmed.dropFirst(4).dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]) else { return nil }
        return Color(
            red: min(max(r / 255.0, 0), 1),
            green: min(max(g / 255.0, 0), 1),
            blue: min(max(b / 255.0, 0), 1)
        )
    }

    private static func deriveRepresentativeColor(from image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        guard let cgImage = bitmap.cgImage else { return nil }
        let sampleSize = 24
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        guard let context = CGContext(
            data: &rawData,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var bestScore: Double = -1
        var bestR: Double = 0, bestG: Double = 0, bestB: Double = 0

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = (y * sampleSize + x) * 4
                let a = Double(rawData[offset + 3]) / 255.0
                guard a > 0.6 else { continue }
                let r = Double(rawData[offset]) / 255.0
                let g = Double(rawData[offset + 1]) / 255.0
                let b = Double(rawData[offset + 2]) / 255.0

                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let delta = maxC - minC
                guard maxC > 0.18 && minC < 0.88 && delta > 0.12 else { continue }

                let score = delta * (1.0 - abs(maxC + minC - 1.0)) * a
                if score > bestScore {
                    bestScore = score
                    bestR = r
                    bestG = g
                    bestB = b
                }
            }
        }

        if bestScore > 0.04 {
            return Color(red: bestR, green: bestG, blue: bestB)
        }
        return nil
    }
}

// MARK: - Start Page Settings Sheet

struct BrowserHomeSettingsSheet: View {
    @ObservedObject var preferences: BrowserPreferences
    @ObservedObject var model: LoginBrowserModel
    @Environment(\.bkPalette) private var palette
    let onDismiss: () -> Void

    @State private var selectedMode: StartPageMode
    @State private var customURLText: String
    @State private var validationError: String?

    init(preferences: BrowserPreferences, model: LoginBrowserModel, onDismiss: @escaping () -> Void) {
        self.preferences = preferences
        self.model = model
        self.onDismiss = onDismiss
        _selectedMode = State(initialValue: preferences.startPageMode)
        _customURLText = State(initialValue: preferences.customHomeURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("시작 페이지 설정")
                    .font(.headline.bold())
                    .foregroundColor(palette.textColor)
                Spacer()
                Button("닫기") { onDismiss() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("설정 닫기")
            }

            Text("새 창을 열거나 홈 버튼을 눌렀을 때 표시할 방식을 선택하세요.")
                .font(.caption)
                .foregroundColor(palette.mutedColor)

            VStack(alignment: .leading, spacing: 10) {
                Picker("시작 방식", selection: $selectedMode) {
                    ForEach(StartPageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if selectedMode == .customURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("시작 웹 주소 (URL):")
                            .font(.caption.bold())
                            .foregroundColor(palette.textColor)

                        TextField("https://example.com", text: $customURLText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("사용자 지정 시작 웹 주소")

                        if let currentURL = model.currentURL,
                           ["http", "https"].contains(currentURL.scheme?.lowercased() ?? "") {
                            Button("현재 열린 페이지 주소 사용 (\(currentURL.host ?? ""))") {
                                customURLText = currentURL.absoluteString
                                validationError = nil
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .accessibilityLabel("현재 열린 페이지를 시작 페이지 주소로 설정")
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.surfaceColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderColor, lineWidth: 1))
                }
            }

            if let err = validationError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button("취소") { onDismiss() }
                    .buttonStyle(.bordered)
                Button("저장") {
                    let result = preferences.setStartPage(mode: selectedMode, customURL: customURLText)
                    if result.success {
                        onDismiss()
                    } else {
                        validationError = result.error ?? "유효한 http 또는 https 주소를 입력해 주세요."
                    }
                }
                .buttonStyle(.bkProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 480)
        .background(palette.cardColor)
    }
}

// MARK: - Edit Bookmark Sheet

struct EditBookmarkSheet: View {
    let bookmark: BookmarkItem
    var categories: [BookmarkCategory] = []
    let onSave: (String, String, UUID?) -> (success: Bool, error: String?)
    let onCancel: () -> Void
    @Environment(\.bkPalette) private var palette
    @State private var urlText: String
    @State private var titleText: String
    @State private var selectedCategoryID: UUID?
    @State private var errorMsg: String?

    init(
        bookmark: BookmarkItem,
        categories: [BookmarkCategory] = [],
        onSave: @escaping (String, String, UUID?) -> (success: Bool, error: String?),
        onCancel: @escaping () -> Void
    ) {
        self.bookmark = bookmark
        self.categories = categories
        self.onSave = onSave
        self.onCancel = onCancel
        _urlText = State(initialValue: bookmark.url)
        _titleText = State(initialValue: bookmark.title)
        _selectedCategoryID = State(initialValue: bookmark.categoryID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("즐겨찾기 편집")
                .font(.headline.bold())
                .foregroundColor(palette.textColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("웹 주소 (URL):").font(.caption.bold()).foregroundColor(palette.textColor)
                TextField("https://...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("즐겨찾기할 웹 주소")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("이름:").font(.caption.bold()).foregroundColor(palette.textColor)
                TextField("즐겨찾기 이름", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("즐겨찾기 이름")
            }

            if !categories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("카테고리:").font(.caption.bold()).foregroundColor(palette.textColor)
                    Picker("카테고리 선택", selection: $selectedCategoryID) {
                        Text("미분류").tag(UUID?.none)
                        ForEach(categories) { cat in
                            Text(cat.name).tag(UUID?.some(cat.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            if let err = errorMsg {
                Text(err)
                    .font(.caption)
                    .foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button("취소") { onCancel() }
                    .buttonStyle(.bordered)
                Button("저장") {
                    let res = onSave(titleText, urlText, selectedCategoryID)
                    if !res.success {
                        errorMsg = res.error
                    }
                }
                .buttonStyle(.bkProminent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(palette.cardColor)
    }
}

// MARK: - Add Bookmark Sheet

struct AddBookmarkSheet: View {
    var categories: [BookmarkCategory] = []
    var initialCategoryID: UUID? = nil
    let onAdd: (String, String, UUID?) -> (success: Bool, error: String?)
    let onCancel: () -> Void
    @Environment(\.bkPalette) private var palette
    @State private var urlText = ""
    @State private var titleText = ""
    @State private var selectedCategoryID: UUID?
    @State private var errorMsg: String?

    init(
        categories: [BookmarkCategory] = [],
        initialCategoryID: UUID? = nil,
        onAdd: @escaping (String, String, UUID?) -> (success: Bool, error: String?),
        onCancel: @escaping () -> Void
    ) {
        self.categories = categories
        self.initialCategoryID = initialCategoryID
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selectedCategoryID = State(initialValue: initialCategoryID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("즐겨찾기 직접 추가")
                .font(.headline.bold())
                .foregroundColor(palette.textColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("웹 주소 (URL):").font(.caption.bold()).foregroundColor(palette.textColor)
                TextField("https://...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("즐겨찾기할 웹 주소")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("이름 (선택 사항):").font(.caption.bold()).foregroundColor(palette.textColor)
                TextField("생략 시 도메인 이름 사용", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("즐겨찾기 이름")
            }

            if !categories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("카테고리:").font(.caption.bold()).foregroundColor(palette.textColor)
                    Picker("카테고리 선택", selection: $selectedCategoryID) {
                        Text("미분류").tag(UUID?.none)
                        ForEach(categories) { cat in
                            Text(cat.name).tag(UUID?.some(cat.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            if let err = errorMsg {
                Text(err)
                    .font(.caption)
                    .foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button("취소") { onCancel() }
                    .buttonStyle(.bordered)
                Button("추가") {
                    let res = onAdd(urlText, titleText, selectedCategoryID)
                    if !res.success {
                        errorMsg = res.error
                    }
                }
                .buttonStyle(.bkProminent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(palette.cardColor)
    }
}

// MARK: - Add Category Sheet

struct AddCategorySheet: View {
    var title: String = "새 카테고리 추가"
    var message: String? = nil
    var confirmTitle: String = "추가"
    let onAdd: (String) -> (success: Bool, error: String?)
    let onCancel: () -> Void
    @Environment(\.bkPalette) private var palette
    @State private var nameText = ""
    @State private var errorMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline.bold())
                .foregroundColor(palette.textColor)

            if let message = message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(palette.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("카테고리 이름:").font(.caption.bold()).foregroundColor(palette.textColor)
                TextField("예: 업무, 뉴스, 비디오", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("새 카테고리 이름")
            }

            if let err = errorMsg {
                Text(err)
                    .font(.caption)
                    .foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button("취소") { onCancel() }
                    .buttonStyle(.bordered)
                Button(confirmTitle) {
                    let res = onAdd(nameText)
                    if !res.success {
                        errorMsg = res.error
                    }
                }
                .buttonStyle(.bkProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(palette.cardColor)
    }
}

// MARK: - Category Rename Sheet

struct CategoryRenameSheet: View {
    let category: BookmarkCategory
    let onSave: (String) -> (success: Bool, error: String?)
    let onCancel: () -> Void
    @Environment(\.bkPalette) private var palette
    @State private var nameText: String
    @State private var errorMsg: String?

    init(category: BookmarkCategory, onSave: @escaping (String) -> (success: Bool, error: String?), onCancel: @escaping () -> Void) {
        self.category = category
        self.onSave = onSave
        self.onCancel = onCancel
        _nameText = State(initialValue: category.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("카테고리 이름 변경")
                .font(.headline.bold())
                .foregroundColor(palette.textColor)

            TextField("카테고리 이름", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("카테고리 새 이름")

            if let err = errorMsg {
                Text(err)
                    .font(.caption)
                    .foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button("취소") { onCancel() }
                    .buttonStyle(.bordered)
                Button("저장") {
                    let res = onSave(nameText)
                    if !res.success {
                        errorMsg = res.error
                    }
                }
                .buttonStyle(.bkProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(palette.cardColor)
    }
}

// MARK: - HTD Share Code Sheet

enum ShareCodeSheetMode: String, Identifiable {
    case export
    case importCode
    var id: String { rawValue }
}

struct ShareCodeSheet: View {
    let mode: ShareCodeSheetMode
    let makeCode: () throws -> String
    let onImport: (String) throws -> Int
    let onClose: () -> Void
    @Environment(\.bkPalette) private var palette
    @State private var code = ""
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var importDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .export ? "HTD 공유 코드 만들기" : "HTD 공유 코드로 가져오기")
                .font(.headline.bold())
                .foregroundColor(palette.textColor)

            Text("사람이 바로 읽기 어려운 짧은 문자열일 뿐 비밀 보호나 변조 방지 수단이 아닙니다. 이 코드를 가진 사람은 누구나 즐겨찾기(제목·주소·분류)를 가져올 수 있습니다. HTD는 이 코드를 업로드하지 않으며, 복사·붙여넣기로만 전달됩니다.")
                .font(.caption)
                .foregroundColor(palette.dangerColor)
                .fixedSize(horizontal: false, vertical: true)

            if mode == .export {
                TextEditor(text: .constant(code))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderColor, lineWidth: 1))
                    .accessibilityLabel("생성된 HTD 공유 코드")
            } else {
                TextEditor(text: $code)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderColor, lineWidth: 1))
                    .accessibilityLabel("HTD 공유 코드 붙여넣기")
            }

            if let resultText = resultText {
                Text(resultText).font(.caption).foregroundColor(palette.textColor)
            }
            if let errorText = errorText {
                Text(errorText).font(.caption).foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button(importDone || mode == .export ? "닫기" : "취소") { onClose() }
                    .buttonStyle(.bordered)
                if mode == .export {
                    Button(code.isEmpty ? "코드 만들어 복사" : "다시 복사") {
                        do {
                            if code.isEmpty { code = try makeCode() }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            resultText = "클립보드에 복사했습니다."
                            errorText = nil
                        } catch {
                            errorText = error.localizedDescription
                            resultText = nil
                        }
                    }
                    .buttonStyle(.bkProminent)
                } else {
                    Button("붙여넣기") {
                        if let text = NSPasteboard.general.string(forType: .string) { code = text }
                    }
                    .buttonStyle(.bordered)
                    .disabled(importDone)
                    Button("가져오기") {
                        do {
                            let count = try onImport(code)
                            resultText = "\(count)개 즐겨찾기를 가져왔습니다."
                            errorText = nil
                            importDone = true
                        } catch {
                            errorText = error.localizedDescription
                            resultText = nil
                        }
                    }
                    .buttonStyle(.bkProminent)
                    .disabled(importDone || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(palette.cardColor)
    }
}

private extension BrowserHomeView {
    enum ExportFormat {
        case httbookmarks
        case markdown
    }

    private static let bookmarkFileSignature = "HTTBookmarks"
    private static let bookmarkFileVersion = 1
    private static let maxRawBookmarkFileSize = 524_288 // 512 KiB
    private static let maxContainerBookmarkFileSize = 4 * ((524_288 + 2) / 3) + 1024 // 4*((512KiB+2)/3)+1024 = 700,056 bytes

    func exportBookmarks(format: ExportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .httbookmarks:
            panel.allowedContentTypes = [UTType(filenameExtension: "httbookmarks") ?? .data]
            panel.nameFieldStringValue = "HTT-즐겨찾기.httbookmarks"
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "HTT-즐겨찾기.md"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.window.appearance = NSApp.keyWindow?.appearance
        do {
            let markdown = preferences.exportBookmarksMarkdown()
            guard let markdownData = markdown.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            guard markdownData.count <= Self.maxRawBookmarkFileSize else {
                throw CocoaError(.fileWriteUnknown)
            }

            switch format {
            case .httbookmarks:
                let base64EncodedData = markdownData.base64EncodedData()
                let plistPayload: [String: Any] = [
                    "format": Self.bookmarkFileSignature,
                    "version": Self.bookmarkFileVersion,
                    "payload": base64EncodedData
                ]
                let binaryData = try PropertyListSerialization.data(fromPropertyList: plistPayload, format: .binary, options: 0)
                try binaryData.write(to: url, options: .atomic)
            case .markdown:
                try markdownData.write(to: url, options: .atomic)
            }
            alert.messageText = "즐겨찾기를 내보냈습니다."
        } catch {
            alert.messageText = "즐겨찾기 파일을 내보낼 수 없습니다."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    func importBookmarks() {
        let panel = NSOpenPanel()
        var types: [UTType] = []
        if let httType = UTType(filenameExtension: "httbookmarks") {
            types.append(httType)
        }
        if let mdType = UTType(filenameExtension: "md") {
            types.append(mdType)
        }
        if let htmlType = UTType(filenameExtension: "html") {
            types.append(htmlType)
        }
        if let htmType = UTType(filenameExtension: "htm") {
            types.append(htmType)
        }
        types.append(contentsOf: [.html, .plainText, .data])
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.window.appearance = NSApp.keyWindow?.appearance
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let readLimit = Self.maxContainerBookmarkFileSize + 1
            let bytes = try file.read(upToCount: readLimit) ?? Data()
            guard bytes.count <= Self.maxContainerBookmarkFileSize else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let ext = url.pathExtension.lowercased()
            let isHttExtension = ext == "httbookmarks"
            let isHTMLExtension = ext == "html" || ext == "htm"
            let hasBplistHeader = bytes.starts(with: [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]) // "bplist"

            let count: Int
            if isHttExtension || hasBplistHeader {
                var format = PropertyListSerialization.PropertyListFormat.xml
                guard let plistObj = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) as? [String: Any],
                      format == .binary,
                      let marker = plistObj["format"] as? String,
                      marker == Self.bookmarkFileSignature,
                      let version = plistObj["version"] as? Int,
                      version == Self.bookmarkFileVersion,
                      let payloadData = plistObj["payload"] as? Data else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                guard let rawData = Data(base64Encoded: payloadData),
                      rawData.count <= Self.maxRawBookmarkFileSize,
                      let decodedString = String(data: rawData, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                count = try preferences.importBookmarksMarkdown(decodedString)
            } else if isHTMLExtension {
                guard bytes.count <= Self.maxRawBookmarkFileSize,
                      let htmlString = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .ascii) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                count = try preferences.importBookmarksHTML(htmlString)
            } else {
                // Could be markdown or HTML file with other/generic extension
                guard bytes.count <= Self.maxRawBookmarkFileSize,
                      let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .ascii) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let lowerText = text.prefix(1024).lowercased()
                if lowerText.contains("<!doctype netscape-bookmark-file") || lowerText.contains("<dl>") || lowerText.contains("<dt>") {
                    count = try preferences.importBookmarksHTML(text)
                } else {
                    count = try preferences.importBookmarksMarkdown(text)
                }
            }

            alert.messageText = "\(count)개 즐겨찾기를 가져왔습니다."
        } catch {
            alert.messageText = "즐겨찾기 파일을 처리할 수 없습니다."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
