# ksystemstats plugin: "CPU temperature (fan controller average)" for the P620.
# Builds for Plasma 5 (Qt5/KF5, e.g. Kubuntu 24.04) and Plasma 6 (Qt6/KF6, e.g. Debian 13).
# The Qt major version is detected (KF6CoreAddons present -> Qt6); force with -DQT_MAJOR_VERSION=5|6.
# Build:   cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
# Install: see ../install.sh (copies the .so next to ksystemstats_plugin_cpu.so)
cmake_minimum_required(VERSION 3.16)
project(ksystemstats_plugin_p620 LANGUAGES CXX)
find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT QT_MAJOR_VERSION)
  find_package(KF6CoreAddons QUIET)
  if(KF6CoreAddons_FOUND)
    set(QT_MAJOR_VERSION 6 CACHE STRING "Qt major version")
  else()
    set(QT_MAJOR_VERSION 5 CACHE STRING "Qt major version")
  endif()
endif()
message(STATUS "Building against Qt${QT_MAJOR_VERSION} / KF${QT_MAJOR_VERSION}")

find_package(Qt${QT_MAJOR_VERSION} REQUIRED COMPONENTS Core DBus)
find_package(KF${QT_MAJOR_VERSION}CoreAddons REQUIRED)
# KSysGuardConfig.cmake drags in IconThemes/I18n/Widgets dev packages we don't need: link the libraries directly.
find_path(KSYSGUARD_INCLUDE systemstats/SensorPlugin.h PATH_SUFFIXES ksysguard REQUIRED)
find_library(KSYSGUARD_SYSTEMSTATS KSysGuardSystemStats REQUIRED)
find_library(KSYSGUARD_FORMATTER KSysGuardFormatter REQUIRED)

add_library(ksystemstats_plugin_p620 MODULE p620plugin.cpp)
set_target_properties(ksystemstats_plugin_p620 PROPERTIES PREFIX "")
target_include_directories(ksystemstats_plugin_p620 PRIVATE ${KSYSGUARD_INCLUDE})
target_link_libraries(ksystemstats_plugin_p620
  Qt${QT_MAJOR_VERSION}::Core Qt${QT_MAJOR_VERSION}::DBus KF${QT_MAJOR_VERSION}::CoreAddons
  ${KSYSGUARD_SYSTEMSTATS} ${KSYSGUARD_FORMATTER})
# libksysguard 6's formatter/Unit.h includes <qqmlregistration.h> (QtQml), so Qt6 builds need Qml too.
if(QT_MAJOR_VERSION EQUAL 6)
  find_package(Qt6 REQUIRED COMPONENTS Qml)
  target_link_libraries(ksystemstats_plugin_p620 Qt6::Qml)
endif()
