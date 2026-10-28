# 开发与发布

## 环境

- macOS 13+
- Swift 6
- Xcode Command Line Tools
- Git

## 测试

```bash
./run-tests.sh
```

测试覆盖布局边界、4～8 列连续性、窗口尺寸容差、最小宽度判断以及单次操作内部重试决策。

## 构建

```bash
./build-app.sh
```

输出：

- `dist/WindowSnap.app`
- `dist/WindowSnap-<version>.zip`

版本号由 `Resources/Info.plist` 管理。

## 签名

默认使用临时签名，仅适合本地使用。正式分发应指定 Developer ID：

```bash
WINDOWSNAP_SIGNING_IDENTITY="Developer ID Application: ..." ./build-app.sh
```

签名后仍需使用 Apple Notary Service 完成公证。本仓库不保存证书、密码或公证凭据。

## 发布流程

1. 更新 `Resources/Info.plist`。
2. 更新 `CHANGELOG.md`。
3. 运行测试和构建。
4. 校验签名和安装包。
5. 提交源码并创建版本标签。
6. 将 ZIP 上传到 GitHub Release，不把构建产物提交到 Git 历史。
