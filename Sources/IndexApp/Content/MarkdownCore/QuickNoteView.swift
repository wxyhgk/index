import SwiftUI
import Combine

// MARK: - 便签 SwiftUI 视图（纯渲染）
//
// 窗口壳（NSPanel / show / close / 动画 / 键盘事件）在 Platform/macOS/QuickNote/QuickNotePanel.swift。
// 业务状态与逻辑在 QuickNoteViewModel。本文件只做渲染。

struct QuickNoteView: View {
    @ObservedObject var viewModel: QuickNoteViewModel

    @State private var hoveredShotID: Int64?

    var body: some View {
        HStack(spacing: 0) {
            if !viewModel.sidebarCollapsed {
                sidebar
                    .frame(width: 220)

                Divider()
            }

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DS.windowBase))
        .onAppear {
            viewModel.onAppear()
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            viewModel.searchChanged()
        }
        .onReceive(viewModel.libraryDidChangePublisher) {
            viewModel.reload()
        }
    }

    // MARK: 左侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 顶部：搜索 + 新建
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .thin))
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $viewModel.searchQuery)
                        .font(.system(size: 12, design: .rounded))
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: { viewModel.newNote() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("新建便签 (⌘N)")
            }
            .padding(10)

            Divider()

            // 列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // 置顶
                        let pinned = viewModel.shots.filter { viewModel.isPinned($0) }
                        if !pinned.isEmpty {
                            Text("置顶")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(pinned) { shot in
                                sidebarRow(shot)
                            }

                            Divider().padding(.horizontal, 10).padding(.vertical, 4)
                        }

                        // 按天分组（排除已置顶的）
                        let unpinned = viewModel.shots.filter { !viewModel.isPinned($0) }
                        let grouped = QuickNoteViewModel.groupByDay(unpinned)
                        ForEach(grouped, id: \.date) { group in
                            Text(QuickNoteViewModel.dayLabel(for: group.date))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(group.shots) { shot in
                                sidebarRow(shot)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: viewModel.selectedShotID) { _, newID in
                    guard !viewModel.sidebarCollapsed, let newID else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: DS.windowBase))
    }

    private func sidebarRow(_ shot: Shot) -> some View {
        let isSelected = viewModel.selectedShotID == shot.id
        let isHovered = hoveredShotID == shot.id
        let isConfirmDelete = viewModel.confirmDeleteID == shot.id
        let isPinned = viewModel.isPinned(shot)
        return HStack(spacing: 6) {
            // 图钉（置顶时始终显示，hover 时也可操作）
            if isPinned || isHovered {
                Button(action: { viewModel.togglePin(shot) }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 8, weight: .thin))
                        .foregroundStyle(isPinned ? .primary : .tertiary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "取消置顶" : "置顶")
            }

            Text(viewModel.shotTitle(for: shot))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovered {
                Button(action: {
                    if isConfirmDelete {
                        viewModel.deleteShot(shot.id ?? 0)
                    } else {
                        viewModel.confirmDeleteID = shot.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            if viewModel.confirmDeleteID == shot.id {
                                viewModel.confirmDeleteID = nil
                            }
                        }
                    }
                }) {
                    Image(systemName: isConfirmDelete ? "trash.fill" : "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(isConfirmDelete ? .red : .secondary)
                        .frame(width: 16, height: 16)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isConfirmDelete ? "再点一次确认删除" : "删除")
                .transition(.opacity)
            } else {
                Text(viewModel.timeLabel(shot.capturedAt))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .id(shot.id ?? 0)
        .onTapGesture {
            if let id = shot.id {
                viewModel.select(shotID: id)
            }
        }
        .onTapGesture(count: 2) { viewModel.copyShot(shot) }
        .onHover { hovering in
            hoveredShotID = hovering ? shot.id : (hoveredShotID == shot.id ? nil : hoveredShotID)
            if !hovering {
                viewModel.confirmDeleteID = nil
            }
        }
        .contextMenu {
            Button("复制源码") { viewModel.copyShot(shot) }
            Button("导出 .md") {
                if let id = shot.id { viewModel.select(shotID: id) }
                viewModel.exportAsMarkdown()
            }
            Divider()
            Button(isPinned ? "取消置顶" : "置顶") { viewModel.togglePin(shot) }
            Divider()
            Button("删除", role: .destructive) { viewModel.deleteShot(shot.id ?? 0) }
        }
    }

    // MARK: 右侧编辑器

    private var editor: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleSidebar()
                    }
                }) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 12, weight: .thin))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("切换侧边栏 (⌘\\)")

                Text(viewModel.selectedTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // 编辑器
            // 不能直接绑 $viewModel.text：SwiftUI 会绕过 updateText，
            // 800ms 防抖保存和 undo 压栈都不会触发。
            MarkdownEditorSurface(text: Binding(
                get: { viewModel.text },
                set: { viewModel.updateText($0) }
            ))
                .padding(14)

            // 待办清单（解析 - [ ] / - [x]）
            let todos = viewModel.todos
            if !todos.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(todos.indices, id: \.self) { i in
                        TodoRow(
                            item: todos[i],
                            onToggle: {
                                viewModel.toggleTodo(at: i)
                            }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            // 工具栏（flomo 风格）
            Divider()
            HStack(spacing: 0) {
                toolbarButton("textformat", help: "标题 (## )") { viewModel.insertSyntax("## ") }
                toolbarButton("list.bullet", help: "无序列表 (- )") { viewModel.insertSyntax("- ") }
                toolbarButton("list.number", help: "有序列表 (1. )") { viewModel.insertSyntax("1. ") }
                toolbarButton("checklist", help: "待办 (- [ ] )") { viewModel.insertSyntax("- [ ] ") }
                toolbarButton("photo", help: "图片 (![]())") { viewModel.insertSyntax("![描述]()") }

                Spacer()

                toolbarButton("square.and.arrow.up", help: "导出 .md") { viewModel.exportAsMarkdown() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // 字数统计
            if !viewModel.text.isEmpty {
                Divider()
                Text(viewModel.wordCount)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .thin))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 待办行

struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(item.done ? .tertiary : .primary)
                .strikethrough(item.done)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
