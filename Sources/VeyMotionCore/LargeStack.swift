import Foundation

/// Runs work on a thread with room for deep renders. Threads started by GCD or `Thread.detachNewThread` get 512 KB
/// of stack, and the design lint's renders need more than that in debug builds (check_design and set_scene crashed
/// every `vmotion --scene` call with SIGBUS). Overflowing a stack is a crash, not an error, so the tool layer and the
/// chat's background review go through here. The main thread (8 MB) and threads that are already big run the work
/// in place, so nothing waits on the main thread.
public enum LargeStack {
    public static let size = 16 << 20

    public static func run<T>(_ work: () -> T) -> T {
        if Thread.isMainThread || pthread_get_stacksize_np(pthread_self()) >= size { return work() }
        return withoutActuallyEscaping(work) { work in
            // The thread holds the box, not the closure: the box lets go of it before this returns.
            let box = Box<T>()
            box.work = work
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                box.value = box.work?()
                done.signal()
            }
            thread.stackSize = size
            thread.start()
            done.wait()
            box.work = nil
            return box.value!
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var work: (() -> T)?
        var value: T?
    }
}
