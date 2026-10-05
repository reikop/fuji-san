#include "fuji_usb.h"
#include <windows.h>
#include <setupapi.h>
#include <initguid.h>
#include <usbiodef.h>
#include <winusb.h>
#include "wpd_camera.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cwctype>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using V = flutter::EncodableValue;
using Map = flutter::EncodableMap;
HANDLE file = INVALID_HANDLE_VALUE;
WINUSB_INTERFACE_HANDLE usb = nullptr;
UCHAR ep_in = 0, ep_out = 0;
WpdCamera wpd;
void Close() {
  wpd.Close();
  if (usb) WinUsb_Free(usb);
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  usb = nullptr; file = INVALID_HANDLE_VALUE; ep_in = ep_out = 0;
}
std::string Utf8(const std::wstring& s) {
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n, nullptr, nullptr);
  return out;
}
std::wstring Wide(const std::string& s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
  return out;
}
flutter::EncodableList Discover() {
  flutter::EncodableList devices;
  for (const auto& device : WpdCamera::Discover()) {
    devices.push_back(V(Map{{V("id"),V("wpd:" + Utf8(device.id))},
                           {V("name"),V(Utf8(device.name) + " (Windows WPD)")}}));
  }
  const GUID guid = GUID_DEVINTERFACE_USB_DEVICE;
  auto set = SetupDiGetClassDevsW(&guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
  if (set == INVALID_HANDLE_VALUE) throw std::runtime_error("USB enumeration failed");
  SP_DEVICE_INTERFACE_DATA data{}; data.cbSize = sizeof(data);
  for (DWORD i=0; SetupDiEnumDeviceInterfaces(set,nullptr,&guid,i,&data); ++i) {
    DWORD size=0; SetupDiGetDeviceInterfaceDetailW(set,&data,nullptr,0,&size,nullptr);
    if (!size) continue;
    std::vector<BYTE> buffer(size);
    auto detail=reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
    detail->cbSize=sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    SP_DEVINFO_DATA info{}; info.cbSize=sizeof(info);
    if (!SetupDiGetDeviceInterfaceDetailW(set,&data,detail,size,nullptr,&info)) continue;
    wchar_t service[256]{};
    if (!SetupDiGetDeviceRegistryPropertyW(set,&info,SPDRP_SERVICE,nullptr,
          reinterpret_cast<PBYTE>(service),sizeof(service),nullptr) || _wcsicmp(service,L"WinUSB")!=0) continue;
    std::wstring path=detail->DevicePath, lower=path;
    std::transform(lower.begin(),lower.end(),lower.begin(),[](wchar_t c){return static_cast<wchar_t>(std::towlower(c));});
    if(lower.find(L"vid_04cb")!=std::wstring::npos) devices.push_back(V(Map{{V("id"),V(Utf8(path))},{V("name"),V("FUJIFILM USB (WinUSB)")}}));
  }
  SetupDiDestroyDeviceInfoList(set); return devices;
}
void Connect(const std::string& id) {
  bool found=false;
  for(const auto& d:Discover()) if(std::get<std::string>(std::get<Map>(d).at(V("id")))==id) found=true;
  if(!found) throw std::runtime_error("Selected FUJIFILM camera is no longer connected");
  Close();
  if(id.rfind("wpd:",0)==0) { wpd.Open(Wide(id.substr(4))); return; }
  auto path=Wide(id);
  file=CreateFileW(path.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
  if(file==INVALID_HANDLE_VALUE || !WinUsb_Initialize(file,&usb)) { Close(); throw std::runtime_error("WinUSB unavailable. Install WinUSB for the camera's PTP interface, or close other camera apps. See README."); }
  USB_INTERFACE_DESCRIPTOR descriptor{};
  if(!WinUsb_QueryInterfaceSettings(usb,0,&descriptor) || descriptor.bInterfaceClass!=6) {Close();throw std::runtime_error("No PTP interface. Select USB RAW CONV./BACKUP RESTORE.");}
  for(UCHAR i=0;i<descriptor.bNumEndpoints;i++) {
    WINUSB_PIPE_INFORMATION pipe{};
    if(WinUsb_QueryPipe(usb,0,i,&pipe) && pipe.PipeType==UsbdPipeTypeBulk) {
      if(pipe.PipeId&0x80) ep_in=pipe.PipeId; else ep_out=pipe.PipeId;
      ULONG timeout=5000; WinUsb_SetPipePolicy(usb,pipe.PipeId,PIPE_TRANSFER_TIMEOUT,sizeof(timeout),&timeout);
    }
  }
  if(!ep_in || !ep_out){Close();throw std::runtime_error("No USB bulk endpoints");}
}
uint32_t Read32(const std::vector<uint8_t>& bytes, size_t offset) {
  return static_cast<uint32_t>(bytes.at(offset)) |
    (static_cast<uint32_t>(bytes.at(offset+1))<<8) |
    (static_cast<uint32_t>(bytes.at(offset+2))<<16) |
    (static_cast<uint32_t>(bytes.at(offset+3))<<24);
}
void Put32(std::vector<uint8_t>& bytes,size_t offset,uint32_t value) {
  for(size_t i=0;i<4;i++) bytes.at(offset+i)=static_cast<uint8_t>((value>>(i*8))&255);
}
V Transaction(const Map& arguments) {
  const auto& command=std::get<std::vector<uint8_t>>(arguments.at(V("command")));
  if(command.size()<12 || command.size()>32 || command.size()%4!=0 ||
      Read32(command,0)!=command.size() || command[4]!=1 || command[5]!=0)
    throw std::runtime_error("Invalid PTP command frame");
  const auto opcode=static_cast<uint16_t>(command[6]|(command[7]<<8));
  std::vector<uint32_t> params;
  for(size_t offset=12;offset<command.size();offset+=4) params.push_back(Read32(command,offset));
  const std::vector<uint8_t>* outgoing=nullptr;
  const auto it=arguments.find(V("outgoing"));
  if(it!=arguments.end()) outgoing=std::get_if<std::vector<uint8_t>>(&it->second);
  const auto reply=wpd.Command(opcode,params,outgoing);
  std::vector<uint8_t> response(12+4*reply.params.size(),0);
  Put32(response,0,static_cast<uint32_t>(response.size()));
  response[4]=3;response[6]=static_cast<uint8_t>(reply.code&255);response[7]=static_cast<uint8_t>(reply.code>>8);
  Put32(response,8,Read32(command,8));
  for(size_t i=0;i<reply.params.size();i++) Put32(response,12+4*i,reply.params[i]);
  return V(Map{{V("response"),V(response)},{V("data"),V(reply.data)}});
}
}  // namespace

void CloseFujiUsb() { Close(); }

void RegisterFujiUsb(flutter::BinaryMessenger* messenger) {
  static auto channel=std::make_unique<flutter::MethodChannel<V>>(messenger,"dev.reikop.fuji_san/usb",&flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call,auto result) {
    try {
      auto method=call.method_name();
      if(method=="discover") { result->Success(V(Discover())); }
      else if(method=="connect") { Connect(std::get<std::string>(std::get<Map>(*call.arguments()).at(V("id")))); result->Success(V(Map{{V("managedSession"),V(wpd.IsOpen())}})); }
      else if(method=="transaction") { result->Success(Transaction(std::get<Map>(*call.arguments()))); }
      else if(method=="disconnect") { Close(); result->Success(); }
      else if(method=="read") {
        if(!usb) throw std::runtime_error("Camera disconnected");
        std::vector<uint8_t> bytes(16384); ULONG n=0;
        if(!WinUsb_ReadPipe(usb,ep_in,bytes.data(),static_cast<ULONG>(bytes.size()),&n,nullptr) || n==0) throw std::runtime_error("USB read failed or timed out");
        bytes.resize(n);result->Success(V(bytes));
      } else if(method=="write") {
        if(!usb) throw std::runtime_error("Camera disconnected");
        auto bytes=std::get<std::vector<uint8_t>>(*call.arguments()); ULONG n=0;
        if(!WinUsb_WritePipe(usb,ep_out,bytes.data(),static_cast<ULONG>(bytes.size()),&n,nullptr) || n!=bytes.size()) throw std::runtime_error("USB write failed or timed out");
        result->Success();
      } else { result->NotImplemented(); }
    } catch(const std::exception& e) { Close(); result->Error("usb",e.what()); }
  });
}
