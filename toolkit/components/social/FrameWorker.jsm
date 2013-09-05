/* -*- Mode: JavaScript; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* vim: set ts=2 et sw=2 tw=80: */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * This is an implementation of a "Shared Worker" using a remote browser
 * in the hidden DOM window.  This is the implementation that lives in the
 * "chrome process".  See FrameWorkerContent for code that lives in the
 * "content" process and which sets up a sandbox for the worker.
 */

"use strict";

const {classes: Cc, interfaces: Ci, utils: Cu} = Components;

Cu.import("resource://gre/modules/Services.jsm");
Cu.import("resource://gre/modules/XPCOMUtils.jsm");
Cu.import("resource://gre/modules/Promise.jsm");

XPCOMUtils.defineLazyModuleGetter(this, "SocialService",
  "resource://gre/modules/SocialService.jsm");

const XUL_NS = "http://www.mozilla.org/keymaster/gatekeeper/there.is.only.xul";
const HTML_NS = "http://www.w3.org/1999/xhtml";

this.EXPORTED_SYMBOLS = ["getFrameWorkerHandle"];

var workerCache = {}; // keyed by URL.
var _nextPortId = 1;

// Retrieves a reference to a WorkerHandle associated with a FrameWorker and a
// new ClientPort.
this.getFrameWorkerHandle =
 function getFrameWorkerHandle(url, clientWindow, name, origin, exposeLocalStorage = false) {
  // prevent data/about urls - see bug 891516
  if (['http', 'https'].indexOf(Services.io.newURI(url, null, null).scheme) < 0)
    throw new Error("getFrameWorkerHandle requires http/https urls");

  // See if we already have a worker with this URL.
  let existingWorker = workerCache[url];
  if (!existingWorker) {
    // create a remote browser and _Worker object - this will message the
    // remote browser to do the content side of things.
    let browserPromise = makeRemoteBrowser();
    let options = { url: url, name: name, origin: origin,
                    exposeLocalStorage: exposeLocalStorage };

    existingWorker = workerCache[url] = new _Worker(browserPromise, options);
  }

  // XXX - this pref will die eventually...
  Services.prefs.setBoolPref("dom.messageChannel.enabled", true);
  // XXX - it seems strange the channel needs a window...
  let someWindow = Services.wm.getMostRecentWindow('navigator:browser');
  let channel = new someWindow.MessageChannel();
  // message the content so it can establish a new connection with the worker.
  existingWorker.browserPromise.then(browser => {
    browser.messageManager.sendAsyncMessage("frameworker:connect",
                                            { port: channel.port2 });
  });
  return new WorkerHandle(channel.port1, existingWorker);
};

// A "_Worker" is an internal representation of a worker.  It's never returned
// directly to consumers.
function _Worker(browserPromise, options) {
  this.browserPromise = browserPromise;
  this.options = options;
  browserPromise.then(browser => {
    let mm = browser.messageManager;
    // execute the content script and send the message to bootstrap the content
    // side of the world.
    mm.loadFrameScript("resource://gre/modules/FrameWorkerContent.js", true);
    mm.sendAsyncMessage("frameworker:init", this.options);
    mm.addMessageListener("frameworker:notify-worker-error", this);
  });
}

_Worker.prototype = {
  // Message handler.
  receiveMessage: function(msg) {
    switch (msg.name) {
      case "frameworker:notify-worker-error":
        notifyWorkerError(msg.data.origin);
        break;
    }
  }
}

// This WorkerHandle is exposed to consumers - it has the new port instance
// the consumer uses to communicate with the worker.
// public methods/properties on WorkerHandle should conform to the SharedWorker
// api - currently that's just .port and .terminate()
function WorkerHandle(port, worker) {
  this.port = port;
  this._worker = worker;
}

WorkerHandle.prototype = {
  // A method to terminate the worker.  The worker spec doesn't define a
  // callback to be made in the worker when this happens, so we just kill the
  // browser element.
  terminate: function terminate() {
    let url = this._worker.options.url;
    if (!(url in workerCache)) {
      // terminating an already terminated worker - ignore it
      return;
    }
    delete workerCache[url];
    // close all the ports we have handed out.
    for (let [portid, port] of this._worker.ports) {
      port.close();
    }
    this._worker.ports.clear();
    this._worker.ports = null;
    this._worker.browserPromise.then(browser => {
      browser.parentNode.removeChild(browser);
    });
    // wipe things out just incase other reference have snuck out somehow...
    this._worker.browserPromise = null;
    this._worker = null;
  }
};

function PortShim(port) {
  this.port = port;
}

PortShim.prototype = {
  close: function() {
    // a leaky abstraction due to the worker spec not specifying how the
    // other end of a port knows it is closing.
    this.port.postMessage({topic: "social.port-closing"});
    this.port = null;
  },

  _JSONParse: function(data) {
    if (this._clientWindow) {
      return XPCNativeWrapper.unwrap(this._clientWindow).JSON.parse(data);
    }
    return JSON.parse(data);
  },

}

// Make the <browser remote="true"> element that hosts the worker.
function makeRemoteBrowser() {
  let deferred = Promise.defer();
  let hiddenDoc = Services.appShell.hiddenDOMWindow.document;
  // Create a HTML iframe with a chrome URL, then this can host the browser.
  let iframe = hiddenDoc.createElementNS(HTML_NS, "iframe");
  iframe.setAttribute("src", "chrome://global/content/mozilla.xhtml");
  iframe.addEventListener("load", function onLoad() {
    iframe.removeEventListener("load", onLoad, true);
    let browser = iframe.contentDocument.createElementNS(XUL_NS, "browser");
    browser.setAttribute("type", "content");
    browser.setAttribute("disableglobalhistory", "true");
    let remote;
    // for now we use the same preference that enabled multiple workers - the
    // idea is that there is no point in having people help test multiple
    // "old" frameworkers - so anyone who wants multiple workers is forced to
    // help us test remote frameworkers too.
    if (Services.prefs.prefHasUserValue("social.allowMultipleWorkers") &&
        Services.prefs.getBoolPref("social.allowMultipleWorkers")) {
      browser.setAttribute("remote", "true");
    }
    iframe.contentDocument.documentElement.appendChild(browser);
    deferred.resolve(browser);
  }, true);
  hiddenDoc.documentElement.appendChild(iframe);
  return deferred.promise;
}

function notifyWorkerError(origin) {
  // Try to retrieve the worker's associated provider, if it has one, to set its
  // error state.
  SocialService.getProvider(origin, function (provider) {
    if (provider)
      provider.errorState = "frameworker-error";
    Services.obs.notifyObservers(null, "social:frameworker-error", origin);
  });
}
