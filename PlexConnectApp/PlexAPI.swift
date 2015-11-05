//
//  PlexAPI.swift
//  PlexConnectApp
//
//  Created by Baa on 29.09.15.
//  Copyright © 2015 Baa. All rights reserved.
//

import Foundation
import UIKit



let httpTimeout: Int64 = Int64(10.0 * Double(NSEC_PER_SEC))



// create class instance (always-on!)
var plexUserInformation = cPlexUserInformation()

class cPlexUserInformation {
    private let _storage = NSUserDefaults.standardUserDefaults()

    private var _attributes: [String: String] = [:]
/*
    private var _name: String
    private var _email: String
    private var _token: String
  */
    private var _xmlUser: XMLIndexer?  // store for debugging - XML data this PMS was set up with

    
    init() {
        _xmlUser = nil
        _attributes = ["name": "", "email": "", "token": ""]

        if let name = _storage.stringForKey("name") {
            _attributes["name"] = name
        }
        if let email = _storage.stringForKey("email") {
            _attributes["email"] = email
        }
        if let token = _storage.stringForKey("token") {
            _attributes["token"] = token
        }
    }
    
    init(xmlUser: XMLIndexer) {
        _xmlUser = xmlUser
        
        // todo: check XML and neccessary nodes
        _attributes["name"] = xmlUser["username"].element!.text!
        _attributes["email"] = xmlUser["email"].element!.text!
        _attributes["token"] = xmlUser["authentication-token"].element!.text!

        store()
    }
    
    func clear() {
        _attributes = ["name": "", "email": "", "token": ""]
    
        store()
    }
    
    private func store() {
        _storage.setObject(_attributes["name"], forKey: "name")
        _storage.setObject(_attributes["email"], forKey: "email")
        _storage.setObject(_attributes["token"], forKey: "token")
    }
    
    func getAttribute(key: String) -> String {
        if let attribute = _attributes[key] {
            return attribute
        }
        return ""
    }
}



// global pms variable to store pms related data, including local and remote connection
var PlexMediaServerInformation: [String: cPlexMediaServerInformation] = [:]

class cPlexMediaServerInformation {
    private var _attributes: [String: String] = [:]
    
    private var _xmlPms: XMLIndexer?  // store for debugging - XML data this PMS was set up with
    private var _fastestConnection: Int? = nil
    
    init(attributes: [String: String]) {
        _attributes = attributes
        _xmlPms = nil
    }
    
    init(xmlPms: XMLIndexer) {
        _xmlPms = xmlPms
        _attributes = xmlPms.element!.attributes
        
        // check server - fire at every connection. fastest response wins
        // multiple threads - wait for one finisher
        // todo: honor publicAddressMatches to double check local vs remote addresses only
        _fastestConnection = nil
        let dsptch = dispatch_semaphore_create(0)
        for (_ix,_con) in xmlPms["Connection"].enumerate() {
  
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
                let config = NSURLSessionConfiguration.defaultSessionConfiguration()
                let session = NSURLSession(configuration: config)
                let url = NSURL(string: _con.element!.attributes["uri"]! + "?X-Plex-Token=" + self._attributes["accessToken"]!)
                let request = NSMutableURLRequest(URL: url!)

                let task = session.dataTaskWithRequest(request) {
                    (data, response, error) -> Void in
                    if let httpResp = response as? NSHTTPURLResponse {
                        //print(String(data: data!, encoding: NSUTF8StringEncoding))
                        if self._fastestConnection == nil {  // todo: thread safe?
                            self._fastestConnection = _ix
                        }
                        dispatch_semaphore_signal(dsptch)
                    }
                }
                task.resume()
            })
        }
        dispatch_semaphore_wait(dsptch, dispatch_time(DISPATCH_TIME_NOW, httpTimeout))  // todo: 10sec timeout?
            
        // add connection details of fastest response to top level _attributes
        if let _ = _fastestConnection {
            for (key, value) in xmlPms["Connection"][_fastestConnection!].element!.attributes {
                self._attributes[key] = value
            }
        }
    }
    
    func getAttribute(key: String) -> String {
        if let attribute = _attributes[key] {
            return attribute
        }
        return ""
    }
}


func getPMSAdr(PMSId: String, PMSPath: String) -> String {

    var queryDelimiter = "?"
    if PMSPath.characters.contains("?") {
        queryDelimiter = "&"
    }
    // todo: if let PMSId
    let URL = PlexMediaServerInformation[PMSId]!.getAttribute("uri") +
              PMSPath +
              queryDelimiter + "X-Plex-Token="+PlexMediaServerInformation[PMSId]!.getAttribute("accessToken")
    print("request: \(URL)")
        return URL
    }



func getVideoPath(video: XMLIndexer, partIx: Int, pmsId: String, pmsPath: String?) -> String {
    var res: String

    // sanity check
    // todo: ?
    
    // XML pointing to Video node
    let media = video["Media"][0]  // todo: cover XMLError, errorchecking on optionals
    let part = media["Part"][partIx]

    // transcoder action
    let transcoderAction = settings.getSetting("transcoderAction")
    
    // video format
    //    HTTP live stream
    // or native aTV media
    var videoATVNative =
        ["hls"].contains(getAttribute(media, key: "protocol", dflt: ""))
        ||
        ["mov", "mp4"].contains(getAttribute(media, key: "container", dflt: "")) &&
        ["mpeg4", "h264", "drmi"].contains(getAttribute(media, key: "videoCodec", dflt: "")) &&
        ["aac", "ac3", "drms"].contains(getAttribute(media, key: "audioCodec", dflt: ""))

    /* limitation of aTV2/3 only?
    for stream in part["Stream"] {
        if (stream.element!.attributes["streamType"] == "1" &&
            ["mpeg4", "h264"].contains(stream.element!.attributes["codec"]!)) {
            if (stream.element!.attributes["profile"] == "high 10" ||
                Int(stream.element!.attributes["refFrames"]!) > 8) {
                    videoATVNative = false
                    break
            }
        }
    }
    */
    print("videoATVNative: " + String(videoATVNative))
    
    // quality limits: quality=(resolution, quality, bitrate)
    let qualityLookup = [
        "480p 2.0Mbps": ("720x480", "60", "2000"),
        "720p 3.0Mbps": ("1280x720", "75", "3000"),
        "720p 4.0Mbps": ("1280x720", "100", "4000"),
        "1080p 8.0Mbps": ("1920x1080", "60", "8000"),
        "1080p 12.0Mbps": ("1920x1080", "90", "12000"),
        "1080p 20.0Mbps": ("1920x1080", "100", "20000"),
        "1080p 40.0Mbps": ("1920x1080", "100", "40000")
    ]
    var quality: [String: String] = [:]
    if plexUserInformation.getAttribute("local") == "1" {
        quality["resolution"] = qualityLookup[settings.getSetting("transcoderQuality")]?.0
        quality["quality"] = qualityLookup[settings.getSetting("transcoderQuality")]?.1
        quality["bitrate"] = qualityLookup[settings.getSetting("transcoderQuality")]?.2
    } else {
        quality["resolution"] = qualityLookup[settings.getSetting("remoteBitrate")]?.0
        quality["quality"] = qualityLookup[settings.getSetting("remoteBitrate")]?.1
        quality["bitrate"] = qualityLookup[settings.getSetting("remoteBitrate")]?.2
    }
    let qualityDirectPlay = Int(getAttribute(media, key: "bitrate", dflt: "0")) < Int(quality["bitrate"]!)
    print("quality: ", quality["resolution"], quality["quality"], quality["bitrate"], "qualityDirectPlay: ", qualityDirectPlay)
    
    // subtitle renderer, subtitle selection
    /* not used yet - todo: implement and test
    let subtitleRenderer = settings.getSetting("subtitleRenderer")
    
    var subtitleId = ""
    var subtitleKey = ""
    var subtitleFormat = ""
    for stream in part["Stream"] {  // todo: check 'Part' existance, deal with multi part video
        if stream.element!.attributes["streamType"] == "3" &&
           stream.element!.attributes["selected"] == "1" {
            subtitleId = stream.element!.attributes["id"]!
            subtitleKey = stream.element!.attributes["key"]!
            subtitleFormat = stream.element!.attributes["format"]!
            break
        }
    }
    
    let subtitleIOSNative = (subtitleKey == "") && (subtitleFormat == "tx3g")  // embedded
    let subtitleThisApp   = (subtitleKey != "") && (subtitleFormat == "srt")  // external

    // subtitle suitable for direct play?
    //    no subtitle
    // or 'Auto'    with subtitle by iOS or ThisApp
    // or 'iOS,PMS' with subtitle by iOS
    let subtitleDirectPlay =
        subtitleId == ""
        ||
        subtitleRenderer == "Auto" && ( (videoATVNative && subtitleIOSNative) || subtitleThisApp )
        ||
        subtitleRenderer == "iOS, PMS" && (videoATVNative && subtitleIOSNative)
    print("subtitle: IOSNative - {0}, PlexConnect - {1}, DirectPlay - {2}", subtitleIOSNative, subtitleThisApp, subtitleDirectPlay)
    */
    
    // determine video URL
    // direct play for...
    //    force direct play
    // or videoATVNative (HTTP live stream m4v/h264/aac...)
    //    limited by quality setting
    //    with aTV supported subtitle (iOS embedded tx3g, PlexConnext external srt)
    let accessToken = PlexMediaServerInformation[pmsId]!.getAttribute("accessToken")
    if transcoderAction == "DirectPlay"
       ||
       transcoderAction == "Auto" && videoATVNative && qualityDirectPlay /*&& subtitleDirectPlay*/ {
        // direct play
        let key = getAttribute(part, key: "key", dflt: "")
        
        let indirect = getAttribute(media, key: "indirect", dflt: "0")
        if indirect=="1" {
            // todo: indirection... typically attribute indirect is not available
            // todo: select suitable resolution, today we just take first Media
        }
        //res = getDirectVideoPath(key, pmsToken: accessToken)
        
        var xargs = getDeviceInfoXArgs()
        if accessToken != "" {
            xargs += [ NSURLQueryItem(name: "X-Plex-Token", value: accessToken) ]
        }
        
        let urlComponents = NSURLComponents(string: key)
        urlComponents!.queryItems = xargs
        
        res = urlComponents!.string!
    } else {
        // request transcoding
        let key = getAttribute(video, key: "key", dflt: "")
        let ratingKey = getAttribute(video, key: "ratingKey", dflt: "")
        
        // misc settings: subtitlesize, audioboost
        /*
        let subtitle = ["selected": "1" if subtitleId else "0",
                        "dontBurnIn": "1" if subtitleDirectPlay else "0",
                        "size": settings.getSetting("subtitlesize") ]
        */
        let audio = ["boost": "100" /*settings.getSetting("audioboost")*/ ]
        
        let args = getTranscodeVideoArgs(key, ratingKey: ratingKey, partIx: partIx,
            transcoderAction: transcoderAction,
            quality: quality,
            audio: audio
            // subtitle: subtitle
            )
        
        var xargs = getDeviceInfoXArgs()
        xargs += [
            NSURLQueryItem(name: "X-Plex-Client-Capabilities", value: "protocols=http-live-streaming,http-mp4-streaming,http-streaming-video,http-streaming-video-720p,http-mp4-video,http-mp4-video-720p;videoDecoders=h264{profile:high&resolution:1080&level:41};audioDecoders=mp3,aac{bitrate:160000}"),
        ]
        if accessToken != "" {
            xargs += [ NSURLQueryItem(name: "X-Plex-Token", value: accessToken) ]
        }
        
        let urlComponents = NSURLComponents(string: "/video/:/transcode/universal/start.m3u8?")
        urlComponents!.queryItems = args + xargs
        
        res = urlComponents!.string!
    }
    
    if res.hasPrefix("/") {
        // internal full path
        res = PlexMediaServerInformation[pmsId]!.getAttribute("uri") + res
    } else if res.hasPrefix("http://") || res.hasPrefix("https://") {
        // external address - do nothing
    } else {
        // internal path, add-on
        res = PlexMediaServerInformation[pmsId]!.getAttribute("uri") + pmsPath! + res
    }
    
    return res
}

func getDirectVideoPath(key: String, pmsToken: String) -> String {
    var res: String
    
    if key.hasPrefix("http://") || key.hasPrefix("https://") {  // external address, eg. channels - keep
        res = key
    } else if pmsToken == "" {  // no token, nothing to add - keep
        res = key
    } else {
        var queryDelimiter = "?"
        if key.characters.contains("?") {
            queryDelimiter = "&"
        }
        res = key + queryDelimiter + "X-Plex-Token=" + pmsToken  // todo: does token need urlencode?
    }

    return res
}

func getTranscodeVideoArgs(path: String, ratingKey: String, partIx: Int, transcoderAction: String, quality: [String: String], audio: [String: String]) -> [NSURLQueryItem] {

    var directStream: String
    if transcoderAction == "Transcode" {
        directStream = "0"  // force transcoding, no direct stream
    } else {
        directStream = "1"
    }
    // transcoderAction 'directPlay' - handled by the client in MEDIARUL()

    let args: [NSURLQueryItem] = [
        NSURLQueryItem(name: "path", value: path),
        NSURLQueryItem(name: "partIndex", value: String(partIx)),
        
        NSURLQueryItem(name: "session", value: ratingKey),  // todo: session UDID? ratingKey?

        NSURLQueryItem(name: "protocol", value: "hls"),
        NSURLQueryItem(name: "videoResolution", value: quality["resolution"]!),
        NSURLQueryItem(name: "videoQuality", value: quality["quality"]!),
        NSURLQueryItem(name: "maxVideoBitrate", value: quality["bitrate"]!),
        NSURLQueryItem(name: "directStream", value: directStream),
        NSURLQueryItem(name: "audioBoost", value: audio["boost"]!),
        NSURLQueryItem(name: "fastSeek", value: "1"),
        
        /* todo: subtitle support
        args["subtitleSize"] = subtitle["size"]
        args["skipSubtitles"] = subtitle["dontBurnIn"]  // '1'  // shut off PMS subtitles. Todo: skip only for aTV native/SRT (or other supported)
        */
        
    ]
    return args
}



func getAudioPath(audio: XMLIndexer, partIx: Int, pmsId: String, pmsPath: String?) -> String {
    var res: String
    
    // sanity check
    // todo: ?
    
    // XML pointing to Track node
    let media = audio["Media"][0]  // todo: cover XMLError, errorchecking on optionals
    let part = media["Part"][partIx]
    
    // todo: transcoder action setting?
    
    var audioATVNative =
        // todo: check Media.get('container') as well - mp3, m4a, ...?
        ["mp3", "aac", "ac3", "drms", "alac", "aiff", "wav"].contains(getAttribute(media, key: "audioCodec", dflt: ""))
    print("audioATVNative: " + String(audioATVNative))
    
    // transcoder bitrate setting [kbps] -  eg. 128, 256, 384, 512?
    var quality: [String: String] = [:]
    quality["bitrate"] = "384"  // maxAudioBitrate  // todo: setting?
    let qualityDirectPlay = Int(getAttribute(media, key: "bitrate", dflt: "0")) < Int(quality["bitrate"]!)
    print("quality: ", quality["bitrate"], "qualityDirectPlay: ", qualityDirectPlay)

    // determine adio URL
    // direct play for...
    //    audioATVNative
    //    limited by quality setting
    let accessToken = PlexMediaServerInformation[pmsId]!.getAttribute("accessToken")
    if audioATVNative && qualityDirectPlay {
        // direct play
        let key = getAttribute(part, key: "key", dflt: "")
        
        var xargs = getDeviceInfoXArgs()
        if accessToken != "" {
            xargs += [ NSURLQueryItem(name: "X-Plex-Token", value: accessToken) ]
        }
        
        let urlComponents = NSURLComponents(string: key)
        urlComponents!.queryItems = xargs
        
        res = urlComponents!.string!
    } else {
        // request transcoding
        let key = getAttribute(audio, key: "key", dflt: "")
        let ratingKey = getAttribute(audio, key: "ratingKey", dflt: "")
        
        let args = getTranscodeAudioArgs(key, ratingKey: ratingKey, quality: quality)
        
        var xargs = getDeviceInfoXArgs()
        if accessToken != "" {
            xargs += [ NSURLQueryItem(name: "X-Plex-Token", value: accessToken) ]
        }
        
        let urlComponents = NSURLComponents(string: "/music/:/transcode/universal/start.mp3?")
        urlComponents!.queryItems = args + xargs
        
        res = urlComponents!.string!
    }
    
    if res.hasPrefix("/") {
        // internal full path
        res = PlexMediaServerInformation[pmsId]!.getAttribute("uri") + res
    } else if res.hasPrefix("http://") || res.hasPrefix("https://") {
        // external address - do nothing
    } else {
        // internal path, add-on
        res = PlexMediaServerInformation[pmsId]!.getAttribute("uri") + pmsPath! + res
    }

    return res
}

func getTranscodeAudioArgs(path: String, ratingKey: String, quality: [String: String]) -> [NSURLQueryItem] {
    
    let args: [NSURLQueryItem] = [
        NSURLQueryItem(name: "path", value: path),
        // mediaIndex
        // partIndex

        NSURLQueryItem(name: "session", value: ratingKey),  // todo: session UDID? ratingKey?
        NSURLQueryItem(name: "protocol", value: "http"),
        NSURLQueryItem(name: "maxAudioBitrate", value: quality["bitrate"]!),
    ]
    return args
}



func getDeviceInfoXArgs() -> [NSURLQueryItem] {
    let device = UIDevice()
    
    let xargs: [NSURLQueryItem] = [
        NSURLQueryItem(name: "X-Plex-Device", value: device.model),
        NSURLQueryItem(name: "X-Plex-Model", value: "4,1"),  // todo: hardware version
        NSURLQueryItem(name: "X-Plex-Device-Name", value: device.name),  // todo: "friendly" name: aTV-Settings->General->Name
        NSURLQueryItem(name: "X-Plex-Platform", value: "iOS" /*device.systemName*/),  // todo: have PMS to accept tvOS
        NSURLQueryItem(name: "X-Plex-Client-Platform", value: "iOS" /*device.systemName*/),
        NSURLQueryItem(name: "X-Plex-Platform-Version", value: device.systemVersion),

        NSURLQueryItem(name: "X-Plex-Client-Identifier", value: device.identifierForVendor?.UUIDString),
        
        NSURLQueryItem(name: "X-Plex-Product", value: "PlexConnectApp"),  // todo: actual App name
        NSURLQueryItem(name: "X-Plex-Version", value: "0.1"),  // todo: version
    ]
    return xargs
}



func reqXML(url: String, fn_success: (NSData) -> (), fn_error: (NSError) -> ()) {
    // request URL asynchronously
    let _nsurl = NSURL(string: url)
    //let config = NSURLSessionConfiguration.defaultSessionConfiguration()
    //let session = NSURLSession(configuration: config)  // previously: convert() loop was done within fn_success closure, leading to thread hang up...
    let session = NSURLSession.sharedSession()
    let task = session.dataTaskWithURL(_nsurl!, completionHandler: { (data, response, error) -> Void in
        // get response
        if let httpResp = response as? NSHTTPURLResponse {
            // todo: check statusCode: 200 ok, 404 not not found...
            //let data_str = NSString(data: data!, encoding: NSUTF8StringEncoding)
            //print("NSData \(data_str)")
            //print("NSURLResponse \(response)")
            //print("NSError \(error)")
            fn_success(data!)
        } else {
            fn_error(error!)
        }
    });
    task.resume()
}



func getXMLWait(url: String) -> XMLIndexer? {
    // request URL, wait for response, parse XML
    var XML: XMLIndexer? = nil
    
    let dsptch = dispatch_semaphore_create(0)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {

        let _nsurl = NSURL(string: url)
        //let session = NSURLSession.sharedSession()
        let session = NSURLSession(configuration: NSURLSessionConfiguration.defaultSessionConfiguration())
        let task = session.dataTaskWithURL(_nsurl!, completionHandler: { (data, response, error) -> Void in
            // get response
            if let httpResp = response as? NSHTTPURLResponse {  // todo: check error, statusCode code
                XML = SWXMLHash.parse(data!)
            } else {
                // error: what to do?
            }
            dispatch_semaphore_signal(dsptch)
        });
        task.resume()
    })
    dispatch_semaphore_wait(dsptch, dispatch_time(DISPATCH_TIME_NOW, httpTimeout))

    return XML
}


// myPlexSignIn
func myPlexSignIn(username: String, password: String) {
    var XML: XMLIndexer?
    
    let config = NSURLSessionConfiguration.defaultSessionConfiguration()
    let userPasswordData = (username + ":" + password).dataUsingEncoding(NSUTF8StringEncoding)
    let base64EncodedCredential = userPasswordData!.base64EncodedStringWithOptions(NSDataBase64EncodingOptions(rawValue:0))
    let authString = "Basic \(base64EncodedCredential)"
    config.HTTPAdditionalHeaders = ["Authorization" : authString]
    let session = NSURLSession(configuration: config)
    
    let url = NSURL(string: "https://plex.tv/users/sign_in.xml")
    let request = NSMutableURLRequest(URL: url!)
    request.HTTPMethod = "POST"

    let xargs = getDeviceInfoXArgs()
    for xarg in xargs {
        request.addValue(xarg.value!, forHTTPHeaderField: xarg.name)
    }

    print("signing in")
    let dsptch = dispatch_semaphore_create(0)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
        let task = session.dataTaskWithRequest(request) {
            (data, response, error) -> Void in
            if let httpResp = response as? NSHTTPURLResponse {
                print(String(data: data!, encoding: NSUTF8StringEncoding))
                XML = SWXMLHash.parse(data!)
            } else {
                // error: what to do?
            }
            dispatch_semaphore_signal(dsptch)
        }
        task.resume()
    })
    dispatch_semaphore_wait(dsptch, dispatch_time(DISPATCH_TIME_NOW, httpTimeout))
    print("sign in done")
    
    // todo: errormanagement. better check of XML, ...
    if (XML != nil && XML!["user"]) {
        plexUserInformation = cPlexUserInformation(xmlUser: XML!["user"])
    } else {
        plexUserInformation.clear()
    }
    
    // re-discover Plex Media Servers
    discoverServers()
}


// myPlexSignOut
func myPlexSignOut() {
    // notify plex.tv
    let url = NSURL(string: "https://plex.tv/users/sign_out.xml")  // + "?X-Plex-Token=" + user._token)
    let request = NSMutableURLRequest(URL: url!)
    request.HTTPMethod = "POST"
    request.addValue(plexUserInformation.getAttribute("token"), forHTTPHeaderField: "X-Plex-Token")
    let session = NSURLSession.sharedSession()
    
    let dsptch = dispatch_semaphore_create(0)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
        let task = session.dataTaskWithRequest(request) {
            (data, response, error) -> Void in
            // ignore response
            dispatch_semaphore_signal(dsptch)
        }
        task.resume()
    })
    dispatch_semaphore_wait(dsptch, dispatch_time(DISPATCH_TIME_NOW, httpTimeout))
    print("sign out done")
    
    // clear user data
    plexUserInformation.clear()
    
    // clear Plex Media Server list
    PlexMediaServerInformation = [:]
}



func discoverServers() {
    // check for servers
    let _url = "https://plex.tv/api/resources?includeHttps=1" +
               "&X-Plex-Token=" + plexUserInformation.getAttribute("token")
    let _xml = getXMLWait(_url)

    PlexMediaServerInformation = [:]
    if (_xml != nil) && (_xml!["MediaContainer"] /*!=XMLError*/) {
        var _pms: cPlexMediaServerInformation
        for (_ix, _server) in _xml!["MediaContainer"]["Device"].enumerate() {
            if (_server.element!.attributes["product"]=="Plex Media Server") {
                _pms = cPlexMediaServerInformation(xmlPms: _server)
                PlexMediaServerInformation[String(_ix)] = _pms
            }
        }
    }
}