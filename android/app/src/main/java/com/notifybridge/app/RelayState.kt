package com.notifybridge.app

object RelayState {
    @Volatile var isRunning: Boolean = false
    @Volatile var bluetoothState: String = "未启动"
    @Volatile var centralConnected: Boolean = false
    @Volatile var paired: Boolean = false
    @Volatile var listenerConnected: Boolean = false
    @Volatile var lastError: String? = null

    // Optional network channels. BLE state above is unchanged.
    @Volatile var lanState: String = "局域网：未启动"
    @Volatile var lanClients: Int = 0
    @Volatile var cloudState: String = "云中转：未配置"
    @Volatile var cloudConnected: Boolean = false

    val networkPaired: Boolean
        get() = lanClients > 0 || cloudConnected
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
