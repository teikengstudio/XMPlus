<div align="center">
  <img width="160" height="160" src="assets/branding/xmplus.png" alt="XMPlus">
  <h1>XMPlus</h1>
  <p>使用 Flutter 开发的喜马拉雅第三方下载与收听客户端</p>

  [![Android CI](https://github.com/teikengstudio/XMPlus/actions/workflows/android.yml/badge.svg)](https://github.com/teikengstudio/XMPlus/actions/workflows/android.yml)
  [![GitHub release](https://img.shields.io/github/v/release/teikengstudio/XMPlus)](https://github.com/teikengstudio/XMPlus/releases/latest)
  [![GitHub downloads](https://img.shields.io/github/downloads/teikengstudio/XMPlus/total)](https://github.com/teikengstudio/XMPlus/releases)
  [![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
</div>

<br/>

> [!IMPORTANT]
> 请不要在国内社交媒体(包括但不限于Bilibili 小红书 贴吧)传播本应用。
> 您将本应用分享给他人时应当主动告知此事！

## 下载

从 [Releases](https://github.com/teikengstudio/XMPlus/releases) 下载。

从[莘应用资源站](https://xinappstore.qiumingsanyu.top/app/1661)下载(大陆推荐)

## 编译

```sh
flutter pub get --enforce-lockfile
bash tool/build_android_media.sh
flutter build apk --release --split-per-abi --no-pub
```


Windows 构建命令见 `licenses/native/SOURCE-MATERIALS-INCOMPLETE.txt`。


## 许可与安全

项目按 [AGPL-3.0-or-later](LICENSE) 提供。第三方组件保留各自许可与版权声明，详见 [NOTICE](NOTICE) 和 `licenses/`。

本项目与喜马拉雅无隶属、合作或背书关系。请遵守平台规则、版权及当地法律。反馈问题时请附应用日志

## 致谢与交流

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：界面与 Windows runner 参考。
- [LinuxDo](https://linux.do/)
- [Flutter](https://flutter.dev/) · [media-kit](https://github.com/media-kit/media-kit) · [Dio](https://pub.dev/packages/dio) · [FFmpeg](https://ffmpeg.org/)
- [GitHub Issues](https://github.com/teikengstudio/XMPlus/issues) · [Telegram](https://t.me/+csbfHjIyqkoyNDA1)
