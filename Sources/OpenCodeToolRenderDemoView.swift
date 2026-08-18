#if DEBUG
import SwiftUI

struct OpenCodeToolRenderDemoView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BYOTBrand.Space.md) {
                    DisclosureGroup("Reasoning") {
                        Text("Checking the project layout and nearby documentation.")
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .padding(.top, BYOTBrand.Space.sm)
                    }
                    .font(.cleanCaptionBold)
                    .tint(.secondary)

                    OpenCodeToolView(
                        name: "bash",
                        state: toolState(
                            command: "ls /home/opencode/dev/okra/apps/okra-computer/src; echo ---; rg -il --glob '!node_modules' 'macos|mac-os|mac os' /home/opencode/dev/okra/scratch --max-count 1 -g 'README*' -g '*.md' 2>/dev/null | head -20",
                            output: "README.md\napps/okra-computer/src"
                        )
                    )

                    DisclosureGroup("Reasoning") {
                        Text("Reviewing repository metadata before making changes.")
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .padding(.top, BYOTBrand.Space.sm)
                    }
                    .font(.cleanCaptionBold)
                    .tint(.secondary)

                    OpenCodeToolView(
                        name: "bash",
                        state: toolState(
                            command: "ls ~/dev 2>/dev/null; ls ~/dev/okra-project 2>/dev/null; gh repo view okra-project/desktop --json name,description,defaultBranchRef 2>&1 | head -20",
                            output: "Repository metadata loaded."
                        )
                    )
                }
                .frame(maxWidth: BYOTBrand.conversationMaxWidth)
                .padding(.horizontal, BYOTBrand.Space.md)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .background(BYOTBrand.canvas)
            .navigationTitle("Tool activity")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func toolState(command: String, output: String) -> OpenCodeToolState {
        OpenCodeToolState(
            status: "completed",
            input: ["command": .string(command)],
            raw: nil,
            title: command,
            output: output,
            error: nil,
            time: nil
        )
    }
}
#endif
