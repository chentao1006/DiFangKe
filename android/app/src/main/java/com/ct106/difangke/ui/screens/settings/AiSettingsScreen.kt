package com.ct106.difangke.ui.screens.settings

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AiSettingsScreen(
    onBack: () -> Unit,
    viewModel: AiSettingsViewModel = viewModel()
) {
    val aiServiceType by viewModel.aiServiceType.collectAsState()
    var customUrl by remember { mutableStateOf("") }
    var customKey by remember { mutableStateOf("") }
    var customModel by remember { mutableStateOf("") }
    
    var isTesting by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<Pair<Boolean, String>?>(null) }

    LaunchedEffect(Unit) {
        customUrl = viewModel.getCustomUrl()
        customKey = viewModel.getCustomKey()
        customModel = viewModel.getCustomModel()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("AI 设置", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            // 服务类型切换
            Column {
                Text("服务类型", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                Spacer(modifier = Modifier.height(12.dp))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                        .padding(4.dp)
                ) {
                    AiTypeTab("公共服务", aiServiceType == "public", Modifier.weight(1f)) {
                        viewModel.setAiServiceType("public")
                    }
                    AiTypeTab("自定义配置", aiServiceType == "custom", Modifier.weight(1f)) {
                        viewModel.setAiServiceType("custom")
                    }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    if (aiServiceType == "public") "公共服务由开发者提供，受每日总额和请求速率限制。" 
                    else "自定义配置允许您使用自己的 API 密钥和代理地址。",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray
                )
            }

            if (aiServiceType == "custom") {
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("API 配置", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    OutlinedTextField(
                        value = customUrl,
                        onValueChange = { customUrl = it; viewModel.setCustomConfig(it, customKey, customModel) },
                        label = { Text("API 地址") },
                        placeholder = { Text("https://api.openai.com/v1") },
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp)
                    )
                    OutlinedTextField(
                        value = customKey,
                        onValueChange = { customKey = it; viewModel.setCustomConfig(customUrl, it, customModel) },
                        label = { Text("API Key") },
                        placeholder = { Text("sk-...") },
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp)
                    )
                    OutlinedTextField(
                        value = customModel,
                        onValueChange = { customModel = it; viewModel.setCustomConfig(customUrl, customKey, it) },
                        label = { Text("模型名称") },
                        placeholder = { Text("gpt-4o-mini") },
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp)
                    )
                }
            }

            // 测试连接
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(
                    onClick = {
                        isTesting = true
                        testResult = null
                        viewModel.testConnection { success, msg ->
                            isTesting = false
                            testResult = success to msg
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    enabled = !isTesting
                ) {
                    if (isTesting) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                    }
                    Text("测试连接")
                }

                if (testResult != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            if (testResult!!.first) Icons.Default.CheckCircle else Icons.Default.Error,
                            contentDescription = null,
                            tint = if (testResult!!.first) Color(0xFF34C759) else Color.Red,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(testResult!!.second, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    }
                }
            }
        }
    }
}

@Composable
fun AiTypeTab(label: String, isSelected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
