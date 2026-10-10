cmake_minimum_required(VERSION 3.15)
project(ligament_endpoint LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(ligament_endpoint endpoint_service.cpp console_host_process.cpp)
# wtsapi32/userenv — Ш5 agent_console_wake; bcrypt — генерация случайных pipe имён для console_host_process
target_link_libraries(ligament_endpoint PRIVATE winhttp ws2_32 advapi32 wtsapi32 userenv bcrypt)

# Реальная версия приложения (из pubspec через build_msi.ps1) — в
# rdp_endpoints.agent_version на сервере; «dev» для ручных cmake-сборок.
if(NOT DEFINED LigamentAgentVersion)
  set(LigamentAgentVersion "dev")
endif()
target_compile_definitions(ligament_endpoint PRIVATE LigamentAgentVersion="${LigamentAgentVersion}")

if(MSVC)
    # статический рантайм: служба не должна тянуть vcruntime.dll
    set_property(TARGET ligament_endpoint PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
    target_compile_options(ligament_endpoint PRIVATE /wd4456 /wd4244)
endif()
