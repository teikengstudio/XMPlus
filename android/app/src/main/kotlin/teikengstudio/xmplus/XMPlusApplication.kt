package teikengstudio.xmplus

import android.app.Application
import android.os.Process
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Process identity survives Flutter engine and Activity recreation. */
class XMPlusApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val metadata = JSONObject()
            .put("sessionId", UUID.randomUUID().toString())
            .put("pid", Process.myPid())
            .put("startedAt", System.currentTimeMillis() * 1000L)
        var target: File? = null
        var atomic: AtomicFile? = null
        var output: FileOutputStream? = null
        try {
            val directory = File(filesDir, "logs")
            if (!directory.exists()) check(directory.mkdirs()) { "Cannot create process log directory" }
            require(OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) { "Log directory is not an ordinary directory" }
            val file = File(directory, ".process-session.json")
            target = file
            if (file.exists()) {
                require(OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) { "Process session metadata is not an ordinary file" }
            }
            atomic = AtomicFile(file)
            output = atomic.startWrite()
            output.write(metadata.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(output)
            output = null
        } catch (error: Exception) {
            try {
                atomic?.failWrite(output)
            } catch (cleanup: Exception) {
                Log.w("XMPlus", "Cannot roll back process session metadata", cleanup)
            }
            target?.let { file ->
                for (path in listOf(file.path, "${file.path}.bak", "${file.path}.new")) {
                    try {
                        val stale = File(path)
                        if (stale.exists()) check(stale.delete()) { "Cannot delete stale process session metadata" }
                    } catch (cleanup: Exception) {
                        Log.w("XMPlus", "Cannot remove stale process session metadata", cleanup)
                    }
                }
            }
            // Filesystem failure must not prevent the application from opening.
            Log.e("XMPlus", "Cannot persist process log session", error)
        }
    }

    companion object {
        private val uploadPromptClaimed = AtomicBoolean(false)

        fun claimLogUploadPrompt(): Boolean = uploadPromptClaimed.compareAndSet(false, true)
    }
}
