// Uses the Windows inbox MTP/PTP driver; no driver replacement is needed.
// Reference: Microsoft Learn, Supporting MTP Extensions.
#include <initguid.h>
#include "wpd_camera.h"
#include <portabledevice.h>
#include <wpdmtpextensions.h>
#include <algorithm>
#include <cwctype>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>

namespace {
using Microsoft::WRL::ComPtr;
using Values = ComPtr<IPortableDeviceValues>;
void Check(HRESULT hr, const char* action) {
  if (FAILED(hr)) {
    std::ostringstream message;
    message << action << " (HRESULT 0x" << std::hex << std::uppercase
            << static_cast<uint32_t>(hr) << "). Close other camera applications and check USB RAW CONV./BACKUP RESTORE mode.";
    throw std::runtime_error(message.str());
  }
}
Values Make(const PROPERTYKEY& key) {
  Values values;
  Check(CoCreateInstance(CLSID_PortableDeviceValues, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&values)), "Create WPD command");
  Check(values->SetGuidValue(WPD_PROPERTY_COMMON_COMMAND_CATEGORY, key.fmtid), "Set command category");
  Check(values->SetUnsignedIntegerValue(WPD_PROPERTY_COMMON_COMMAND_ID, key.pid), "Set command ID");
  return values;
}
Values Send(IPortableDevice* device, IPortableDeviceValues* input) {
  Values output;
  Check(device->SendCommand(0, input, &output), "Send WPD command");
  HRESULT status = E_FAIL;
  Check(output->GetErrorValue(WPD_PROPERTY_COMMON_HRESULT, &status), "Read WPD command status");
  Check(status, "WPD camera command");
  return output;
}
void Parameters(IPortableDeviceValues* input, uint16_t opcode, const std::vector<uint32_t>& params) {
  Check(input->SetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_OPERATION_CODE, opcode), "Set PTP opcode");
  ComPtr<IPortableDevicePropVariantCollection> collection;
  Check(CoCreateInstance(CLSID_PortableDevicePropVariantCollection, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&collection)), "Create PTP parameters");
  for (const auto n : params) {
    PROPVARIANT value{}; value.vt = VT_UI4; value.ulVal = n;
    Check(collection->Add(&value), "Add PTP parameter");
  }
  Check(input->SetIPortableDevicePropVariantCollectionValue(WPD_PROPERTY_MTP_EXT_OPERATION_PARAMS, collection.Get()), "Set PTP parameters");
}
struct FreeCoMemory { void operator()(void* p) const { CoTaskMemFree(p); } };
std::wstring Context(IPortableDeviceValues* output) {
  PWSTR raw = nullptr;
  Check(output->GetStringValue(WPD_PROPERTY_MTP_EXT_TRANSFER_CONTEXT, &raw), "Read transfer context");
  std::unique_ptr<wchar_t, FreeCoMemory> owned(raw);
  return raw;
}
Values ForContext(const PROPERTYKEY& key, const std::wstring& context) {
  auto request = Make(key);
  Check(request->SetStringValue(WPD_PROPERTY_MTP_EXT_TRANSFER_CONTEXT, context.c_str()), "Set transfer context");
  return request;
}
void ReadResponse(IPortableDeviceValues* result, WpdReply& reply) {
  DWORD code = 0;
  Check(result->GetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_RESPONSE_CODE, &code), "Read PTP response");
  if (code > 0xffff) throw std::runtime_error("Invalid PTP response code");
  reply.code = static_cast<uint16_t>(code);
  ComPtr<IPortableDevicePropVariantCollection> params;
  if (SUCCEEDED(result->GetIPortableDevicePropVariantCollectionValue(WPD_PROPERTY_MTP_EXT_RESPONSE_PARAMS, &params))) {
    DWORD count = 0; Check(params->GetCount(&count), "Count response parameters");
    if (count > 5) throw std::runtime_error("Too many PTP response parameters");
    for (DWORD i = 0; i < count; ++i) {
      PROPVARIANT value{};
      Check(params->GetAt(i, &value), "Read response parameter");
      const bool valid = value.vt == VT_UI4;
      const uint32_t number = value.ulVal;
      PropVariantClear(&value);
      if (!valid) throw std::runtime_error("Invalid PTP response parameter type");
      reply.params.push_back(number);
    }
  }
}
}

std::vector<WpdCameraDevice> WpdCamera::Discover() {
  ComPtr<IPortableDeviceManager> manager;
  Check(CoCreateInstance(CLSID_PortableDeviceManager, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&manager)), "Create WPD manager");
  Check(manager->RefreshDeviceList(), "Refresh WPD devices");
  DWORD count = 0;
  Check(manager->GetDevices(nullptr, &count), "Count WPD devices");
  if (!count) return {};
  std::vector<PWSTR> ids(count, nullptr);
  const HRESULT status = manager->GetDevices(ids.data(), &count);
  std::vector<WpdCameraDevice> found;
  for (const auto raw : ids) {
    if (!raw) continue;
    std::unique_ptr<wchar_t, FreeCoMemory> owned(raw);
    if (FAILED(status)) continue;
    std::wstring id = raw, lower = id;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    if (lower.find(L"vid_04cb") == std::wstring::npos) continue;
    DWORD length = 0;
    manager->GetDeviceFriendlyName(raw, nullptr, &length);
    std::vector<wchar_t> name(length ? length : 1, L'\0');
    const HRESULT nameStatus = length ? manager->GetDeviceFriendlyName(raw, name.data(), &length) : E_FAIL;
    found.push_back({id, SUCCEEDED(nameStatus) ? std::wstring(name.data()) : L"FUJIFILM"});
  }
  Check(status, "Enumerate WPD devices");
  return found;
}
void WpdCamera::Open(const std::wstring& id) {
  const auto devices = Discover();
  if (std::none_of(devices.begin(), devices.end(), [&](const auto& d) { return d.id == id; }))
    throw std::runtime_error("Selected FUJIFILM WPD camera is no longer connected");
  Close();
  Values client;
  Check(CoCreateInstance(CLSID_PortableDeviceValues, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&client)), "Create WPD client");
  Check(client->SetStringValue(WPD_CLIENT_NAME, L"Fuji San"), "Set WPD client name");
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_MAJOR_VERSION, 0), "Set client version");
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_MINOR_VERSION, 1), "Set client version");
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_REVISION, 2), "Set client revision");
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_SECURITY_QUALITY_OF_SERVICE, SECURITY_IMPERSONATION), "Set WPD security");
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_DESIRED_ACCESS, GENERIC_READ | GENERIC_WRITE), "Set WPD access");
  Check(CoCreateInstance(CLSID_PortableDeviceFTM, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&device_)), "Create WPD device");
  try { Check(device_->Open(id.c_str(), client.Get()), "Open WPD camera"); }
  catch (...) { device_.Reset(); throw; }
}
void WpdCamera::Close() {
  if (device_) { device_->Close(); device_.Reset(); }
}
WpdReply WpdCamera::Command(uint16_t opcode, const std::vector<uint32_t>& params,
                           const std::vector<uint8_t>* outgoing) {
  if (!device_) throw std::runtime_error("WPD camera is disconnected");
  if (params.size() > 5) throw std::runtime_error("Too many PTP parameters");
  // WPD owns the PTP session; never issue OpenSession/CloseSession through it.
  if (!(opcode == 0x1001 || opcode == 0x1014 || opcode == 0x1015 || opcode == 0x1016))
    throw std::runtime_error("This WPD transport only accepts recipe operations");
  if ((opcode == 0x1016) != (outgoing != nullptr)) throw std::runtime_error("Invalid PTP data direction");
  if (outgoing && outgoing->size() > 1024 * 1024) throw std::runtime_error("PTP write exceeds recipe size limit");
  WpdReply reply;
  auto begin = Make(outgoing ? WPD_COMMAND_MTP_EXT_EXECUTE_COMMAND_WITH_DATA_TO_WRITE : WPD_COMMAND_MTP_EXT_EXECUTE_COMMAND_WITH_DATA_TO_READ);
  Parameters(begin.Get(), opcode, params);
  if (outgoing) Check(begin->SetUnsignedLargeIntegerValue(WPD_PROPERTY_MTP_EXT_TRANSFER_TOTAL_DATA_SIZE, outgoing->size()), "Set write length");
  auto started = Send(device_.Get(), begin.Get());
  // Rejected operations can return a response directly, without a data context.
  PWSTR rawContext = nullptr;
  const HRESULT contextStatus = started->GetStringValue(WPD_PROPERTY_MTP_EXT_TRANSFER_CONTEXT, &rawContext);
  CoTaskMemFree(rawContext);
  if (FAILED(contextStatus)) { ReadResponse(started.Get(), reply); return reply; }
  const std::wstring context = Context(started.Get());
  bool ended = false;
  try {
    DWORD optimal = 16384;
    DWORD reported = 0;
    if (SUCCEEDED(started->GetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_OPTIMAL_TRANSFER_BUFFER_SIZE, &reported)) && reported)
      optimal = std::min<DWORD>(reported, 65536);
    if (outgoing) {
      size_t offset = 0;
      while (offset < outgoing->size()) {
        const DWORD n = static_cast<DWORD>(std::min<size_t>(optimal, outgoing->size() - offset));
        auto request = ForContext(WPD_COMMAND_MTP_EXT_WRITE_DATA, context);
        Check(request->SetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_TRANSFER_NUM_BYTES_TO_WRITE, n), "Set write chunk length");
        Check(request->SetBufferValue(WPD_PROPERTY_MTP_EXT_TRANSFER_DATA, const_cast<BYTE*>(outgoing->data() + offset), n), "Set write chunk");
        auto response = Send(device_.Get(), request.Get());
        DWORD written = 0;
        Check(response->GetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_TRANSFER_NUM_BYTES_WRITTEN, &written), "Read write count");
        if (written == 0 || written > n) throw std::runtime_error("Invalid WPD write count");
        offset += written;
      }
    } else {
      ULONGLONG total = 0;
      Check(started->GetUnsignedLargeIntegerValue(WPD_PROPERTY_MTP_EXT_TRANSFER_TOTAL_DATA_SIZE, &total), "Read transfer length");
      const bool unknown = total == 0xffffffffULL;
      if (!unknown && total > 1024 * 1024) throw std::runtime_error("PTP read exceeds recipe size limit");
      while (unknown || reply.data.size() < total) {
        const DWORD n = unknown ? optimal : static_cast<DWORD>(std::min<ULONGLONG>(optimal, total - reply.data.size()));
        std::vector<BYTE> buffer(n);
        auto request = ForContext(WPD_COMMAND_MTP_EXT_READ_DATA, context);
        Check(request->SetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_TRANSFER_NUM_BYTES_TO_READ, n), "Set read chunk length");
        Check(request->SetBufferValue(WPD_PROPERTY_MTP_EXT_TRANSFER_DATA, buffer.data(), n), "Set read buffer");
        auto response = Send(device_.Get(), request.Get());
        DWORD received = 0, length = 0; BYTE* raw = nullptr;
        Check(response->GetUnsignedIntegerValue(WPD_PROPERTY_MTP_EXT_TRANSFER_NUM_BYTES_READ, &received), "Read received count");
        Check(response->GetBufferValue(WPD_PROPERTY_MTP_EXT_TRANSFER_DATA, &raw, &length), "Read PTP data");
        std::unique_ptr<BYTE, FreeCoMemory> owned(raw);
        if (received > length || received > n) throw std::runtime_error("Invalid WPD read length");
        if (received) reply.data.insert(reply.data.end(), raw, raw + received);
        if (reply.data.size() > 1024 * 1024) throw std::runtime_error("PTP response exceeds recipe size limit");
        if (unknown && received < n) break;
        if (!received) throw std::runtime_error("Truncated WPD read");
      }
    }
    auto finish = ForContext(WPD_COMMAND_MTP_EXT_END_DATA_TRANSFER, context);
    auto response = Send(device_.Get(), finish.Get());
    ended = true;
    ReadResponse(response.Get(), reply);
  } catch (...) {
    if (!ended) {
      try { auto finish = ForContext(WPD_COMMAND_MTP_EXT_END_DATA_TRANSFER, context); Send(device_.Get(), finish.Get()); } catch (...) {}
    }
    throw;
  }
  return reply;
}
