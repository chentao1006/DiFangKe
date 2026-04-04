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
    
    var body: some View {
        Form {
            Section {
                Picker("服务类型", selection: $aiServiceType) {
                    ForEach(AiServiceType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
                Button("重置为默认值") {
                    customAiUrl = "https://api.openai.com/v1"
                    customAiModel = "gpt-4o-mini"
                    // We don't reset API Key for safety
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("AI 设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AiSettingsView()
    }
}
