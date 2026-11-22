package com.github.wgh136.venera

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import android.os.RemoteException

/** Keeps a foreground activity alive while the old Flutter process exits. */
class RestartActivity : Activity() {
    private var resumed = false
    private var originalProcess: IBinder? = null
    private var restartPrepared = false
    private var originalProcessExited = false
    private val deathRecipient = IBinder.DeathRecipient {
        runOnUiThread {
            originalProcessExited = true
            launchIfReady()
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        resumed = true
        if (!restartPrepared) {
            val oldPid = intent.getIntExtra(EXTRA_PID, 0)
            val token = intent.extras?.getBinder(EXTRA_PROCESS)
            if (oldPid <= 0 || oldPid == Process.myPid() || token == null) {
                finish()
                return
            }
            restartPrepared = true
            try {
                // Wait for confirmed process death before starting the main activity.
                token.linkToDeath(deathRecipient, 0)
                originalProcess = token
                Process.killProcess(oldPid)
            } catch (_: RemoteException) {
                originalProcessExited = true
            }
        }
        launchIfReady()
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onDestroy() {
        originalProcess?.unlinkToDeath(deathRecipient, 0)
        super.onDestroy()
    }

    private fun launchIfReady() {
        if (!resumed || !originalProcessExited || isFinishing) return
        val main = ComponentName(this, MainActivity::class.java)
        startActivity(Intent.makeRestartActivityTask(main))
        finish()
    }

    companion object {
        private const val EXTRA_PID = "venera.restart.pid"
        private const val EXTRA_PROCESS = "venera.restart.process"

        fun createIntent(activity: Activity): Intent =
            Intent(activity, RestartActivity::class.java).putExtras(Bundle().apply {
                putInt(EXTRA_PID, Process.myPid())
                putBinder(EXTRA_PROCESS, Binder())
            })
    }
}
