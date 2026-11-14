#include "taskbar_controls.h"

#include <shobjidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cwchar>
#include <tuple>

namespace {
constexpr UINT kPrevious = 0x4D40;
constexpr UINT kPlayPause = 0x4D41;
constexpr UINT kNext = 0x4D42;
enum class Glyph { previous, play, pause, next };

void Report(const wchar_t* operation, HRESULT result) noexcept {
  wchar_t message[160]{};
  swprintf_s(message, L"XMPlus taskbar %s: 0x%08X\n", operation,
             static_cast<unsigned int>(result));
  ::OutputDebugStringW(message);
}

COLORREF Foreground() noexcept {
  HIGHCONTRASTW contrast{sizeof(contrast)};
  if (::SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) &&
      (contrast.dwFlags & HCF_HIGHCONTRASTON)) {
    return ::GetSysColor(COLOR_BTNTEXT);
  }
  DWORD light = 1;
  DWORD size = sizeof(light);
  ::RegGetValueW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  return light ? RGB(40, 40, 40) : RGB(245, 245, 245);
}

bool Inside(Glyph glyph, double x, double y) noexcept {
  if (glyph == Glyph::pause) {
    return y >= .2 && y <= .8 &&
           ((x >= .28 && x <= .43) || (x >= .57 && x <= .72));
  }
  if (glyph == Glyph::previous) x = 1.0 - x;
  if (glyph != Glyph::play) {
    if (x >= .73 && x <= .82 && y >= .2 && y <= .8) return true;
    return x >= .2 && x <= .67 && std::abs(y - .5) <= (.67 - x) * .66;
  }
  return x >= .3 && x <= .78 && std::abs(y - .5) <= (.78 - x) * .67;
}

// Render small antialiased, premultiplied-alpha icons without depending on an
// installed icon font. Windows supplies hover, pressed and disabled visuals.
HICON MakeIcon(Glyph glyph, int width, int height, COLORREF color) noexcept {
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* storage = nullptr;
  HBITMAP bitmap = ::CreateDIBSection(nullptr, &info, DIB_RGB_COLORS,
                                      &storage, nullptr, 0);
  if (!bitmap) return nullptr;
  auto pixels = static_cast<uint32_t*>(storage);
  constexpr int samples = 4;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      int covered = 0;
      for (int sy = 0; sy < samples; ++sy) {
        for (int sx = 0; sx < samples; ++sx) {
          covered += Inside(glyph, (x + (sx + .5) / samples) / width,
                             (y + (sy + .5) / samples) / height) ? 1 : 0;
        }
      }
      const uint32_t alpha = covered * 255 / (samples * samples);
      pixels[y * width + x] = (alpha << 24) |
          (GetRValue(color) * alpha / 255 << 16) |
          (GetGValue(color) * alpha / 255 << 8) |
          (GetBValue(color) * alpha / 255);
    }
  }
  HBITMAP mask = ::CreateBitmap(width, height, 1, 1, nullptr);
  HDC dc = mask ? ::CreateCompatibleDC(nullptr) : nullptr;
  HICON icon = nullptr;
  if (dc) {
    const auto previous = ::SelectObject(dc, mask);
    ::PatBlt(dc, 0, 0, width, height, BLACKNESS);
    ::SelectObject(dc, previous);
    ::DeleteDC(dc);
    ICONINFO icon_info{};
    icon_info.fIcon = TRUE;
    icon_info.hbmColor = bitmap;
    icon_info.hbmMask = mask;
    icon = ::CreateIconIndirect(&icon_info);
  }
  if (mask) ::DeleteObject(mask);
  ::DeleteObject(bitmap);
  return icon;
}

auto StateKey(const TaskbarControls::State& state) noexcept {
  return std::tie(state.visible, state.playing, state.previous,
                  state.play, state.pause, state.next);
}
}  // namespace

struct TaskbarControls::Impl {
  HWND window;
  UINT created_message = ::RegisterWindowMessageW(L"TaskbarButtonCreated");
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar;
  std::array<HICON, 4> icons{};
  State state;
  bool ready = false;
  bool added = false;
  bool dirty = true;

  explicit Impl(HWND hwnd) : window(hwnd) {
    // Explorer normally runs unelevated. Limit its required messages to this
    // window instead of changing the filter for the whole process.
    if (created_message) {
      ::ChangeWindowMessageFilterEx(window, created_message, MSGFLT_ALLOW, nullptr);
    }
    ::ChangeWindowMessageFilterEx(window, WM_COMMAND, MSGFLT_ALLOW, nullptr);
  }

  ~Impl() {
    for (const auto icon : icons) if (icon) ::DestroyIcon(icon);
  }

  bool RefreshIcons() noexcept {
    const auto dpi = ::GetDpiForWindow(window);
    const auto width = std::clamp(::GetSystemMetricsForDpi(SM_CXICON, dpi), 16, 256);
    const auto height = std::clamp(::GetSystemMetricsForDpi(SM_CYICON, dpi), 16, 256);
    const auto color = Foreground();
    const std::array<Glyph, 4> glyphs{
        Glyph::previous, Glyph::play, Glyph::pause, Glyph::next};
    std::array<HICON, 4> next{};
    for (size_t i = 0; i < next.size(); ++i) {
      next[i] = MakeIcon(glyphs[i], width, height, color);
      if (!next[i]) {
        for (const auto icon : next) if (icon) ::DestroyIcon(icon);
        return false;
      }
    }
    for (const auto icon : icons) if (icon) ::DestroyIcon(icon);
    icons = next;
    return true;
  }

  void Apply() noexcept {
    if (!ready || !dirty) return;
    if (!taskbar) {
      auto result = ::CoCreateInstance(CLSID_TaskbarList, nullptr,
          CLSCTX_INPROC_SERVER, IID_PPV_ARGS(taskbar.ReleaseAndGetAddressOf()));
      if (SUCCEEDED(result)) result = taskbar->HrInit();
      if (FAILED(result)) {
        taskbar.Reset();
        Report(L"initialize", result);
        return;
      }
    }
    if (!icons[0] && !RefreshIcons()) return;
    const std::array<UINT, 3> ids{kPrevious, kPlayPause, kNext};
    const std::array<HICON, 3> images{
        icons[0], icons[state.playing ? 2 : 1], icons[3]};
    const std::array<const wchar_t*, 3> labels{
        L"上一集", state.playing ? L"暂停" : L"播放", L"下一集"};
    const std::array<bool, 3> enabled{
        state.previous, state.playing ? state.pause : state.play, state.next};
    std::array<THUMBBUTTON, 3> buttons{};
    for (size_t i = 0; i < buttons.size(); ++i) {
      auto& button = buttons[i];
      button.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
      button.iId = ids[i];
      button.hIcon = images[i];
      wcscpy_s(button.szTip, labels[i]);
      button.dwFlags = !state.visible ? THBF_HIDDEN :
          enabled[i] ? THBF_ENABLED : THBF_DISABLED;
    }
    const auto result = added
        ? taskbar->ThumbBarUpdateButtons(window, static_cast<UINT>(buttons.size()), buttons.data())
        : taskbar->ThumbBarAddButtons(window, static_cast<UINT>(buttons.size()), buttons.data());
    if (SUCCEEDED(result)) {
      added = true;
      dirty = false;
    } else {
      Report(added ? L"update" : L"add", result);
    }
  }

  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     Action& action) noexcept {
    action = Action::none;
    if (created_message && message == created_message) {
      // This also arrives when Explorer recreates the taskbar. An old toolbar
      // and COM interface must not suppress registration on the new taskbar.
      taskbar.Reset();
      added = false;
      ready = true;
      dirty = true;
      Apply();
      return true;
    }
    if (message == WM_THEMECHANGED || message == WM_SETTINGCHANGE ||
        message == WM_DPICHANGED) {
      if (RefreshIcons()) {
        dirty = true;
        Apply();
      }
      return false;
    }
    if (message != WM_COMMAND || HIWORD(wparam) != THBN_CLICKED || lparam != 0) {
      return false;
    }
    const auto id = LOWORD(wparam);
    if (id != kPrevious && id != kPlayPause && id != kNext) return false;
    if (state.visible && ready && added) {
      if (id == kPrevious && state.previous) action = Action::previous;
      if (id == kNext && state.next) action = Action::next;
      if (id == kPlayPause) {
        if (state.playing && state.pause) action = Action::pause;
        if (!state.playing && state.play) action = Action::play;
      }
    }
    return true;
  }
};

TaskbarControls::TaskbarControls(HWND window)
    : impl_(std::make_unique<Impl>(window)) {}

TaskbarControls::~TaskbarControls() = default;

void TaskbarControls::Update(State state) noexcept {
  if (StateKey(state) != StateKey(impl_->state)) {
    impl_->state = state;
    impl_->dirty = true;
  }
  impl_->Apply();
}

bool TaskbarControls::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                    Action& action) noexcept {
  return impl_->HandleMessage(message, wparam, lparam, action);
}
