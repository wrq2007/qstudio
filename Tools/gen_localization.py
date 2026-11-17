#!/usr/bin/env python3
"""生成 en.lproj / zh-Hans.lproj 的 Localizable.strings。

译文集中在这里维护。key = 源码里的中文原文（SwiftUI 的 LocalizedStringKey 拿它查表）。
只收录"显示给用户"的文案；发给模型的 prompt、日志、自检假数据一律不收录，
这样它们会原样 fallback，不会被误翻译。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 中文原文 -> 英文。非插值文案；带插值的在下面 INTERP 单独处理。
T = {
    # 通用动作
    "取消": "Cancel", "删除": "Delete", "保存": "Save", "创建": "Create",
    "关闭": "Close", "完成": "Done", "重试": "Retry", "恢复": "Restore",
    "使用": "Use", "设置": "Settings", "更多": "More", "推荐": "Recommended",
    "当前": "Current", "昨天": "Yesterday", "刚刚": "Just now",
    "清空": "Clear", "重命名": "Rename", "归档": "Archive", "取消归档": "Unarchive",
    "已下载": "Downloaded", "使用中": "In use",
    "新建工作组": "New group", "重命名工作组": "Rename group",
    "新建工作组": "New group", "工作组名称": "Group name",
    "加到工作组": "Add to group", "删除组": "Delete group",
    "关闭提示": "Dismiss", "重新加载模型": "Reload model", "查看运行日志": "View logs",
    "在访达中显示": "Reveal in Finder", "打开模型目录": "Open models folder",
    "清空全部": "Clear all",

    # 侧栏
    "对话历史": "Chats", "工作组": "Groups", "全部对话": "All chats",
    "未分组": "Ungrouped",     "还没有对话": "No chats yet", "还没有内容": "No content yet",
    "聊一句就会自动出现在这里": "Start a chat and it will appear here",
    "新对话": "New chat", "新对话 ⌘N": "New chat ⌘N",
    "当前已经是新对话了": "Already a new chat",
    "删除工作组？": "Delete group?", "删除这段对话？": "Delete this chat?",
    "设置：系统提示词、上下文默认值": "Settings: system prompt, context defaults",

    # 关于/状态
    "检测硬件…": "Detecting hardware…", "已停止": "Stopped",
    "加载模型…": "Loading model…", "就绪": "Ready", "启动失败": "Failed to start",
    "未选择模型": "No model selected", "未选择": "Not selected",
    "绘图中…": "Rendering…", "SVG 绘图": "SVG drawing",
    "复制 SVG 源码": "Copy SVG source", "保存为 .svg 文件": "Save as .svg",
    "复制代码": "Copy code", "代码": "Code",

    # 设置页
    "界面语言": "Interface Language", "切换后立即生效，无需重启。": "Takes effect immediately, no restart needed.",
    "通用": "General", "归档对话": "Archives", "关于": "About",
    "搜索归档对话": "Search archived chats", "没有匹配的归档对话": "No matching archived chats",
    "搜索对话": "Search chats", "没有匹配的对话": "No matching chats",
    "全部对话": "All chats", "未分组": "Ungrouped",
    "对话保存在本机\n~/Library/Application Support/LocalModel":
        "Chats are stored locally\n~/Library/Application Support/LocalModel",
    "系统提示词": "System prompt", "默认上下文长度": "Default context length",
    "归档的对话": "Archived chats", "关于": "About", "当前模型": "Current model",
    "模型目录": "Models folder", "对话记录": "Chat history", "架构": "Architecture",
    "清空所有归档？": "Clear all archives?", "删除归档？": "Delete archive?",
    "还没有归档的对话。在对话列表右键可以归档。": "No archived chats. Right-click a chat to archive it.",
    "这段话会作为 system 提示，每次请求都带上，用来引导模型怎么回答。留空就是不加引导。":
        "Sent as the system prompt on every request to steer how the model replies. Leave empty for no guidance.",
    "例如：你是一个地质学导师，回答时先给结论再给依据。":
        "e.g. You are a geology tutor. State the conclusion first, then the evidence.",

    # 模型管理（只提供网页链接，不在 app 内下载）
    "本机模型": "Local models", "获取模型": "Get Models", "模型管理": "Models",
    "关闭": "Close",
    "估算显存": "Est. VRAM", "KV 缓存": "KV cache",
    "显存": "VRAM", "上下文": "Context",
    "显存估算 = 权重文件 + KV 缓存(fp16) + 运行时开销(0.6 GB + 权重×5%)。只是估算，实际占用随上下文长度浮动。":
        "VRAM estimate = weights + KV cache (fp16) + runtime overhead (0.6 GB + weights×5%). Estimate only; actual usage varies with context.",

    # 复杂插值拆分出来的前缀/后缀片段（L(片段) + 数字，保证 100% 命中）
    "建议": "Suggest", "建议用": "recommends", "按": "Based on",
    "改用推荐的": "Use recommended", "权重": "weights", "条消息": "messages",
    "装不下": "can't hold", "的 KV 缓存": "KV cache (~",
    "模型可能加载失败或回退到内存，速度大降。建议不超过": "). The model may fail to load or fall back to memory. Keep at or below",
    "段对话": "chats", "这": "These",
    "段归档对话及其全部消息会被永久删除，删了就找不回来了。":
        "archived chats and all their messages will be permanently deleted. This cannot be undone.",
    "显存和当前模型（权重": "GB VRAM and the current model (weights",
    "打开网页": "Open page", "浏览全部 GGUF 模型": "Browse all GGUF models",
    "~/models、~/Downloads 和 App Support 里都没找到 .gguf 文件。\n到「获取模型」查看推荐链接，下载后放进这些目录。":
        "No .gguf files found in ~/models, ~/Downloads, or App Support.\nSee Get Models for recommended links, then place downloads there.",
    "Q Studio 不在应用内下载模型。点击下面的链接在浏览器中打开，下载 .gguf 后放进 ~/models、~/Downloads 或 App Support 目录，回到「本机模型」即可使用。":
        "Q Studio does not download models in-app. Open the links below in your browser, download a .gguf into ~/models, ~/Downloads, or App Support, then use it from Local models.",
    "打开模型目录": "Open models folder",

    # 运行/推理错误提示（显示给用户的）
    "应用包不完整：找不到内置推理引擎": "App package incomplete: bundled inference engine not found",
    "还没有可用的 GGUF 模型文件": "No usable GGUF model file yet",
    "加载超时（超过 5 分钟）": "Loading timed out (over 5 minutes)",
    "Vulkan 后端没有找到可用显卡。请确认 AMD 显卡驱动正常、未被其他进程独占。":
        "Vulkan backend found no usable GPU. Check that the AMD driver works and isn't held by another process.",
    "服务器没有返回有效响应": "Server returned no valid response",
    "读不到对话文件，已另存原件。本次是空对话。": "Couldn't read the chat file; original saved separately. Starting empty.",
    "对话文件损坏，原件已另存为 sessions.corrupt.json，本次从空对话开始。":
        "Chat file is corrupt; original saved as sessions.corrupt.json. Starting empty.",

    # 硬件提示
    "硬件性能提示": "Hardware performance note",
    # 列表相对时间（Lf 填数字）
    "无法写入 Vulkan 配置": "Could not write Vulkan config",
    "苹果芯片走的是统一内存 + 原生 Metal 后端，llama.cpp、Ollama、LM Studio 都能直接吃满 GPU，不需要也不应该经 MoltenVK 转发。装这个反而更慢。":
        "Apple silicon uses unified memory with the native Metal backend; llama.cpp, Ollama and LM Studio all use the GPU directly. Routing through MoltenVK is slower, not faster.",
    "系统没有报告任何 Metal 加速器，无法运行推理。请确认显卡驱动已正确安装。":
        "No Metal accelerator reported, so inference cannot run. Check that the GPU driver is installed.",

    "这是 Apple Silicon 机器": "This is an Apple Silicon Mac",
    "没有可用的 GPU": "No GPU available",
    "未知": "Unknown", "未知处理器": "Unknown processor",
    "未检测到 Metal 加速器": "No Metal accelerator detected",

    # 对话区
    "用三句话解释板块运动": "Explain plate tectonics in three sentences",
    "写一个 Python 的快速排序": "Write a quicksort in Python",
    "玄武岩和花岗岩成因上有什么区别？": "How do basalt and granite differ in origin?",
    "试着问点什么": "Ask something to get started",
    "所有计算都在本机完成，不联网": "Everything runs on this Mac — no network",
    "全部计算在本机完成，不联网": "All computation happens on this Mac — no network",
    "运行日志": "Runtime log", "补充说明…": "Add a note…",
    "可多选，选完点右下角发送": "Multiple choices allowed; tap Send when done",
    "选一项，也可以直接在下面输入引导": "Pick one, or type your own guidance below",
    "直接在下面输入来引导模型": "Type below to guide the model",
    "停止生成（也可以直接在下面输入来引导）": "Stop generating (or type below to guide)",
    "你想从哪几个方面深入？": "Which angles would you like to explore?",
    "关掉，继续正常对话": "Turn off and continue normally",
    "重试": "Retry", "发送（Enter）": "Send (Enter)",
    "深度思考": "Deep Thinking", "思考过程": "Reasoning",
    "说点什么…": "Say something…", "（暂无输出）": "(no output yet)",
    "效率提升与系统搭建": "Efficiency & system setup",
    "应对拖延与专注力管理": "Procrastination & focus",
    "优先级排序与目标拆解": "Prioritization & goal breakdown",
    "工作与生活的平衡": "Work-life balance",
    "其他补充…": "Other…", "其他": "Other", "其它": "Other", "补充": "Add",
    "其他/补充/other": "Other / add",

    # 硬件信息标签
    "处理器": "Processor", "系统": "System", "显卡": "GPU",
    "显存可能不够": "Possibly not enough VRAM",
    "KV 缓存随长度线性增长，改完会重新加载模型": "KV cache grows linearly with length; changing it reloads the model",
    "适用范围：Intel x86_64 处理器 + AMD 独立显卡（Polaris / Vega / Navi），macOS 14 及以上。":
        "Supported: Intel x86_64 + AMD discrete GPU (Polaris / Vega / Navi), macOS 14+.",

    # 帮助 tooltip
    "开启深度思考，显示推理过程（会重载模型）": "Enable Deep Thinking to show reasoning (reloads model)",
    "关闭深度思考（会重载模型）": "Disable Deep Thinking (reloads model)",
    "调整上下文长度": "Adjust context length",
    "在设置里修改系统提示词": "Edit system prompt in Settings",
    "重启推理服务": "Restart inference service",

    # 显存档位
    "轻量": "Light", "高质量": "High quality", "通用": "General",
    "中文": "Chinese", "英文": "English", "多语言": "Multilingual",
    "代码": "Code", "数学": "Math", "推理": "Reasoning", "测试": "Test",
    "长文本": "Long context", "超显存": "Exceeds VRAM", "偏紧": "Tight",
    "超出显存": "Out of VRAM",

    # 模型简介 blurb
    "最小可用档位。显存占用低、生成快，适合先跑通链路。": "Smallest usable tier. Low VRAM, fast generation — good for a first run.",
    "同款模型的无损档位，1.8 GB 也能塞进 8 GB 显存。": "Lossless tier of the same model; fits in 8 GB VRAM.",
    "综合性价比最高的一档。中文和日常问答都够用，显存占用不到 3 GB。": "Best overall value. Good for Chinese and everyday Q&A, under 3 GB VRAM.",
    "3B 的高精度档，量化损失更小，速度略降。": "Higher-precision 3B tier: less quantization loss, slightly slower.",
    "3B 的无损档，体积换精度，8 GB 显存跑起来仍然宽裕。": "Lossless 3B tier: size for accuracy, still comfortable on 8 GB.",
    "7B 的推荐档。推理与代码明显强于 3B，本机实测约 20 tok/s。": "Recommended 7B tier. Clearly stronger at reasoning and code than 3B.",
    "7B 的高精度档，8 GB 显存跑它会偏紧，长上下文容易溢出。": "High-precision 7B tier; tight on 8 GB, long contexts may overflow.",
    "610 MB 的小模型。测链路、调参、验证部署都够用。": "610 MB model, enough for pipeline checks and tuning.",
    "新一代 4B，中文语感与指令遵循都比 2.5 代好一截，显存同样只占 3 GB 出头。": "Next-gen 4B: better Chinese fluency and instruction following than 2.5, still ~3 GB.",
    "8B 档位。权重 4.7 GB 加 1.1 GB KV 缓存，8 GB 显存属于偏紧。": "8B tier: 4.7 GB weights + 1.1 GB KV cache — tight on 8 GB.",
    "8 GB 显存装不下。想跑它需要 16 GB 卡，或把上下文砍到 2K 硬挤。": "Won't fit in 8 GB. Needs a 16 GB card or a 2K context squeeze.",
    "Meta 的 3B，多语言和英文更顺，中文一般。": "Meta's 3B: strong in English and multilingual, average in Chinese.",
    "谷歌 4B，长上下文表现好。注意它的 KV 缓存有 1 GB 以上。": "Google's 4B: good at long context. Note its KV cache exceeds 1 GB.",
    "微软 3.8B，数学和代码不错。它是 MHA，KV 缓存特别大，估算占用会明显偏高。": "Microsoft's 3.8B: good at math and code. Uses MHA, so its KV cache is unusually large.",
    "Phi-3.5 的高精度档，KV 缓存依旧占 3 GB。": "High-precision Phi-3.5 tier; KV cache still about 3 GB.",
    "带思维链的推理模型。会先输出一大段思考再给正文，需要把输入框右下角的「深度思考」打开。": "Chain-of-thought reasoning model. Emits a long reasoning block before the answer — enable Deep Thinking at the bottom right of the input box.",
    "经典 7B，英文指令跟随稳，中文偏弱。": "Classic 7B: solid English instruction following, weaker in Chinese.",
    "权重本身就 8.4 GB，8 GB 显存的卡放不下。": "Weights alone are 8.4 GB — won't fit on an 8 GB card.",
}

# 带插值的文案：key 写成 SwiftUI 生成的 %@ 形式；value 用 %@ 占位。
INTERP = {
    "已占用 %@ / %@ tokens": "Used %@ / %@ tokens",
    "建议 %@K": "Suggest %@K",
    "当前是 Intel 核显（%@）：与系统内存共享带宽，推理速度会明显偏慢，建议选 1.5B 以下的小模型并把上下文调到 2K–4K。":
        "Intel integrated GPU detected (%@): shares bandwidth with system memory, so inference is much slower. Use a sub-1.5B model and a 2K–4K context.",
    "检测到 NVIDIA 显卡（%@）。请确认已安装 NullMoth 1401 / nvidia-macos-driver 且 Metal 状态为 supported——没有 Metal 驱动时 MoltenVK 看不到这张卡，推理会退回 CPU 或失败。":
        "NVIDIA GPU detected (%@). Make sure NullMoth 1401 / nvidia-macos-driver is installed and Metal shows 'supported' — without a Metal driver, MoltenVK cannot see the card and inference falls back to CPU or fails.",
    "未识别的显卡型号（%@），性能表现未知，建议先用小模型试跑。":
        "Unrecognized GPU (%@); performance is unknown. Try a small model first.",
    "模型还没准备好（%@），等加载完再发。": "Model not ready (%@). Wait until loading finishes.",
    "模型还没准备好（%@），等加载完再问。": "Model not ready (%@). Wait until loading finishes.",
    "服务器返回 HTTP %@": "Server returned HTTP %@",
    "出错了：%@": "Error: %@",
    "下载失败：HTTP %@": "Download failed: HTTP %@",

    # ModelManagerView 带插值的页脚/指标
    "估算显存 %@ GB": "Est. VRAM %@ GB",
    "KV 缓存 %@ GB": "KV cache %@ GB",
    "显存 %@ GB · 上下文 %@": "VRAM %@ GB · Context %@",
    "显存估算 = 权重文件 + KV 缓存(fp16, ctx %@) + 运行时开销(0.6 GB + 权重×5%)。只是估算，实际占用随上下文长度浮动。":
        "VRAM estimate = weights + KV cache (fp16, ctx %@) + runtime overhead (0.6 GB + weights×5%). Estimate only; actual usage varies with context.",

    # ContentView 上下文/显存档位
    "建议 %lldK": "Suggest %lldK",
    "改用推荐的 %lldK": "Use recommended %lldK",
    "上下文 %@": "Context %@",
    "显存 %@ GB 装不下 %@K 的 KV 缓存（约 %@ GB）。模型可能加载失败或回退到内存，速度大降。建议不超过 %@K。":
        "%@ GB VRAM can't hold the %@K KV cache (~%@ GB). The model may fail to load or fall back to memory, slowing down significantly. Keep at or below %@K.",


    # 列表相对时间
    "%lld分钟前": "%lld min ago",
    "%lld小时前": "%lld h ago",
    "%lld天前": "%lld days ago",
    # 硬件信息 / 架构摘要
    "%lld 层": "%lld layers",
    "%lld 个 KV 头": "%lld KV heads",
    "显存约 %.1f GB，偏小：只能跑 1.5B 以下的量化模型，长上下文会溢出到内存导致变慢。":
        "About %.1f GB VRAM — on the small side. Only quantized models under 1.5B will run; long contexts spill to system memory and slow down.",
    # 确认框
    "仍然改用 %@": "Use %@ anyway",
    "「%@」会被删除，组里的对话会变成未分组（对话本身不删）。":
        "\u201c%@\u201d will be deleted. Its chats move to Ungrouped (the chats themselves are kept).",
    "「%@」及其消息会一起删掉，删了就找不回来了。":
        "\u201c%@\u201d and its messages will be deleted. This cannot be undone.",
    "「%@」将被永久删除。": "\u201c%@\u201d will be permanently deleted.",
    "（中断：%@）": " (interrupted: %@)",
    # 服务错误
    "推理进程退出（状态码 %lld）": "Inference process exited (status %lld)",
    "无法启动推理进程：%@": "Could not start the inference process: %@",

    # SettingsView 归档/上下文
    "清空 %lld 段对话": "Clear %lld chats",
    "这 %lld 段归档对话及其全部消息会被永久删除，删了就找不回来了。":
        "These %lld archived chats and all their messages will be permanently deleted. This cannot be undone.",
    "%lld 条消息": "%lld messages",
    "按 %@ GB 显存和当前模型（权重 %@ GB，KV 缓存 %@ GB）建议用 %lldK。":
        "Based on %@ GB VRAM and the current model (weights %@ GB, KV cache %@ GB), %lldK is recommended.",
}

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def write_lproj(lang, table):
    d = os.path.join(ROOT, 'Resources', lang + '.lproj')
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, 'Localizable.strings')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('/* Generated by Tools/gen_localization.py — do not edit by hand */\n\n')
        for k in sorted(table):
            f.write('"%s" = "%s";\n' % (esc(k), esc(table[k])))
    return path

en = dict(T); en.update(INTERP)
zh = {k: k for k in en}  # 中文表：key 直接回退成自己，保证中文环境原样显示
p1 = write_lproj('en', en)
p2 = write_lproj('zh-Hans', zh)
print('en  :', p1, len(en), 'entries')
print('zh  :', p2, len(zh), 'entries')
