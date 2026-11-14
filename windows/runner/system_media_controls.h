#ifndef RUNNER_SYSTEM_MEDIA_CONTROLS_H_
#define RUNNER_SYSTEM_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// HWND-backed SMTC; it never creates or owns a playback engine.
class SystemMediaControls {
 public:
  static constexpr UINT kMessage = WM_APP + 0x4D3;

  SystemMediaControls(HWND window, flutter::BinaryMessenger* messenger);
  ~SystemMediaControls();

  SystemMediaControls(const SystemMediaControls&) = delete;
  SystemMediaControls& operator=(const SystemMediaControls&) = delete;

  void ProcessEvents() noexcept;
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam) noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_SYSTEM_MEDIA_CONTROLS_H_
