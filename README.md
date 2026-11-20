# singbox-panel

图形化节点命令面板 + 配套一键脚本 `sb.sh`：在网页上点选协议、填端口，自动拼出 SSH 一键命令，粘贴到服务器执行即可装好 sing-box 多协议节点。

## 面板

GitHub Pages：https://walx0705.github.io/singbox-panel/

也可以直接打开本仓库的 `index.html` 使用（纯静态，无后端）。

## 一键命令长这样

```bash
HYPT=2082 VLRT=2083 bash <(curl -Ls https://raw.githubusercontent.com/walx0705/singbox-panel/main/sb.sh) install
```

环境变量（留空 = 不启用）：

| 变量 | 含义 |
|---|---|
| HYPT | Hysteria2 端口 |
| VLRT | VLESS-Reality 端口 |
| TUPT | TUIC 端口 |
| ANYPT | AnyTLS 端口 |
| ADDR | 服务器地址（链接用，默认自动取公网 IP） |
| SNI | 自签证书名，默认 www.bing.com |
| RSNI | Reality 目标站，默认 www.microsoft.com |
| UUID / HPWD / TPWD / APWD | 指定凭据，默认生成并保存在目标机 |

动作（命令最后的词）：`install` 安装 · `rep` 按新端口重组配置（凭据沿用） · `list` 查看链接 · `status` 状态 · `start` / `stop` / `restart` · `del` 卸载。

## 说明

- 一个 sing-box 实例同时跑多个协议，数据存在目标机 `~/sb-node/`（配置、证书、密钥、links.txt、sing-box.log）。
- 有 systemd 用 systemd 托管；无 systemd 的沙盒（如 Altare）自动 nohup 托管。
- 脚本不内置任何密码；密码、UUID、Reality 密钥都在目标机生成，`secrets` 文件权限 600。
- 与 server-toolbox 仓库相互独立：那边是菜单式工具箱，这边是面板拼命令 + 参数化脚本。
