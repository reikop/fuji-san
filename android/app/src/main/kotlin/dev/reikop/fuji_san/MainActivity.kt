package dev.reikop.fuji_san

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val manager by lazy { getSystemService(Context.USB_SERVICE) as UsbManager }
    private var connection: UsbDeviceConnection? = null
    private var claimed: UsbInterface? = null
    private var input: UsbEndpoint? = null
    private var output: UsbEndpoint? = null
    private var permissionReceiver: BroadcastReceiver? = null
    private val permissionAction = "dev.reikop.fuji_san.USB_PERMISSION"

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.reikop.fuji_san/usb").setMethodCallHandler { call, result ->
            if (call.method == "discover") {
                result.success(manager.deviceList.values.filter { it.vendorId == 0x04cb }.map {
                    mapOf("id" to it.deviceName, "name" to (it.productName ?: "FUJIFILM USB"))
                })
            } else if (call.method == "connect") {
                val device = manager.deviceList[call.argument<String>("id")]
                if (device == null || device.vendorId != 0x04cb) { result.error("device", "FUJIFILM camera not found", null); return@setMethodCallHandler }
                if (manager.hasPermission(device)) open(device, result) else requestPermission(device, result)
            } else {
                worker.execute {
                    try {
                        val value: Any? = when (call.method) {
                            "disconnect" -> { closeUsb(); null }
                            "write" -> {
                                val bytes = call.arguments as ByteArray
                                val usb = connection ?: error("Camera disconnected")
                                val endpoint = output ?: error("No bulk output")
                                var offset = 0
                                while (offset < bytes.size) {
                                    val n = usb.bulkTransfer(endpoint, bytes, offset, minOf(16384, bytes.size-offset), 5000)
                                    if (n <= 0) error("USB write failed or timed out")
                                    offset += n
                                }
                                null
                            }
                            "read" -> {
                                val bytes = ByteArray(16384)
                                val n = (connection ?: error("Camera disconnected")).bulkTransfer(input ?: error("No bulk input"), bytes, bytes.size, 5000)
                                if (n <= 0) error("USB read failed or timed out")
                                bytes.copyOf(n)
                            }
                            else -> { runOnUiThread { result.notImplemented() }; return@execute }
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) {
                        closeUsb()
                        runOnUiThread { result.error("usb", e.message, null) }
                    }
                }
            }
        }
    }
    private fun requestPermission(device: UsbDevice, result: MethodChannel.Result) {
        if (permissionReceiver != null) { result.error("busy", "USB permission is pending", null); return }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != permissionAction) return
                @Suppress("DEPRECATION")
                val selected = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                if (selected?.deviceName != device.deviceName) return
                unregisterReceiver(this); permissionReceiver = null
                if (manager.hasPermission(device)) open(device, result)
                else result.error("permission", "USB access was denied", null)
            }
        }
        permissionReceiver = receiver
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, IntentFilter(permissionAction), Context.RECEIVER_NOT_EXPORTED)
        else { @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(receiver, IntentFilter(permissionAction)) }
        val pending = PendingIntent.getBroadcast(this, 0, Intent(permissionAction).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE)
        manager.requestPermission(device, pending)
        android.os.Handler(mainLooper).postDelayed({
            if (permissionReceiver === receiver) {
                unregisterReceiver(receiver); permissionReceiver = null
                result.error("timeout", "USB permission timed out. Try connecting again.", null)
            }
        }, 60000)
    }
    private fun open(device: UsbDevice, result: MethodChannel.Result) {
        worker.execute {
            try {
                closeUsb()
                val usb = manager.openDevice(device) ?: error("Cannot open USB camera")
                connection = usb
                for (i in 0 until device.interfaceCount) {
                    val intf = device.getInterface(i)
                    // Only claim the PTP still-image interface, never arbitrary vendor interfaces.
                    if (intf.interfaceClass != UsbConstants.USB_CLASS_STILL_IMAGE) continue
                    val endpoints = (0 until intf.endpointCount).map { intf.getEndpoint(it) }.filter { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
                    val epIn = endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_IN }
                    val epOut = endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_OUT }
                    if (epIn != null && epOut != null && usb.claimInterface(intf, true)) {
                        claimed = intf; input = epIn; output = epOut; break
                    }
                }
                if (claimed == null) error("No PTP interface. Select USB RAW CONV./BACKUP RESTORE on the camera.")
                runOnUiThread { result.success(mapOf("managedSession" to false)) }
            } catch (e: Exception) { closeUsb(); runOnUiThread { result.error("usb", e.message, null) } }
        }
    }
    private fun closeUsb() {
        claimed?.let { connection?.releaseInterface(it) }
        connection?.close(); connection = null; claimed = null; input = null; output = null
    }
    override fun onDestroy() {
        permissionReceiver?.let { unregisterReceiver(it) }; permissionReceiver = null
        worker.execute { closeUsb() }; worker.shutdown()
        super.onDestroy()
    }
}
