package com.notifybridge.app

object RelayState {
    @Volatile var isRunning: Boolean = false
    @Volatile var bluetoothState: String = "未启动"
    @Volatile var centralConnected: Boolean = false
    @Volatile var paired: Boolean = false
    @Volatile var listenerConnected: Boolean = false
    @Volatile var lastError: String? = null
}

object NotificationHub {
    @Volatile private var sink: ((String) -> Unit)? = null

    fun setSink(newSink: ((String) -> Unit)?) {
        sink = newSink
    }

    fun emit(payload: String) {
        sink?.invoke(payload)
    }
}
