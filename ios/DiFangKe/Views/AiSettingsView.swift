import SwiftUI

struct AiSettingsView: View {
    @AppStorage("aiServiceType") private var aiServiceType: AiServiceType = .public
    @AppStorage("customAiUrl") private var customAiUrl = "https://api.openai.com/v1"
    @AppStorage("customAiKey") private var customAiKey = ""
    @AppStorage("customAiModel") private var customAiModel = "gpt-4o-mini"
    
    enum AiServiceType: String, CaseIterable, Identifiable {
        case `public` = "public"
        case custom = "custom"
        var id: String { self.rawValue }
        
        var displayName: String {
            switch self {
            case .public: return "公共 AI 服务"
            case .custom: return "自定义配置"
            }
        }
    }
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)?
    @Namespace private var aiModeNamespace
    
    var body: some View {
        Form {
            Section {
                HStack(spacing: 0) {
                    ForEach(AiServiceType.allCases) { type in
                        AiServiceTypeTab(
                            type: type,
                            isSelected: aiServiceType == type,
                            namespace: aiModeNamespace
                        ) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                aiServiceType = type
                            }
                        }
                    }
                }
                .padding(4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("服务类型")
            } footer: {
                if aiServiceType == .public {
                    Text("公共服务由开发者提供，受每日总额和请求速率限制。")
                } else {
                    Text("自定义配置允许您使用自己的 API 密钥和代理地址。")
                }
            }
            
            if aiServiceType == .custom {
                Section(header: Text("API 配置")) {
                    HStack {
                        Text("API 地址").frame(width: 80, alignment: .leading)
                        TextField("https://api.openai.com/v1", text: $customAiUrl)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    
                    HStack {
                        Text("API Key").frame(width: 80, alignment: .leading)
                        SecureField("sk-xxxxxxxxxxxxxx", text: $customAiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    
                    HStack {
                        Text("模型名称").frame(width: 80, alignment: .leading)
                        TextField("gpt-4o-mini", text: $customAiModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            
            Section {
                Button(action: testConnection) {
                    HStack {
                        Text("测试连接")
                        if isTesting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isTesting)
                
                if let result = testResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.success ? .green : .red)
                        Text(result.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("AI 设置")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        OpenAIService.shared.testConnection { success, message in
            isTesting = false
            testResult = (success, message)
        }
    }
}

struct AiServiceTypeTab: View {
    let type: AiSettingsView.AiServiceType
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    
    var body: some View {
        Text(type.displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.dfkAccent)
                            .matchedGeometryEffect(id: "ai_mode_bg", in: namespace)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

#Preview {
    NavigationStack {
        AiSettingsView()
    }
}
