#ifndef RUNNER_TASKBAR_CONTROLS_H_
#define RUNNER_TASKBAR_CONTROLS_H_

#include <windows.h>

#include <memory>

// The thumbnail toolbar follows the existing system media session. It owns no
// player and sends commands back through that session's Flutter channel.
class TaskbarControls {
 public:
  enum class Action { none, previous, play, pause, next };
  struct State {
    bool visible = false;
    bool playing = false;
    bool previous = false;
    bool play = false;
    bool pause = false;
    bool next = false;
  };

  explicit TaskbarControls(HWND window);
  ~TaskbarControls();

  TaskbarControls(const TaskbarControls&) = delete;
  TaskbarControls& operator=(const TaskbarControls&) = delete;

  void Update(State state) noexcept;
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     Action& action) noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_TASKBAR_CONTROLS_H_
