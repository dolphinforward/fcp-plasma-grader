//
// main.swift
//
// FxPlug 4 service entry point. FxPrincipal owns the XPC protocol negotiation
// and instantiates the FxTileableEffect class declared in the service plist.

import Foundation
import FxPlug

FxPrincipal.startServicePrincipal()
