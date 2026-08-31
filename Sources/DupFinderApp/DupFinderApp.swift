import SwiftUI

@main
struct DupFinderApp: App {
    @StateObject private var vm = ScanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .commands {
            // ⌘Z 撤销上一次删除（把文件从废纸篓移回原位置）
            CommandGroup(replacing: .undoRedo) {
                Button("撤销删除") { vm.undoLastDeletion() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!vm.canUndo)
            }
        }
    }
}
