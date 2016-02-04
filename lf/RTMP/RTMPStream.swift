import UIKit
import Foundation
import AVFoundation

public class RTMPStream: EventDispatcher, RTMPMuxerDelegate {

    enum ReadyState:UInt8 {
        case Initilized = 0
        case Open = 1
        case Play = 2
        case Playing = 3
        case Publish = 4
        case Publishing = 5
        case Closed = 6
    }

    public enum PlayTransitions: String {
        case Append = "append"
        case AppendAndWait = "appendAndWait"
        case Reset = "reset"
        case Resume = "resume"
        case Stop = "stop"
        case Swap = "swap"
        case Switch = "switch"
    }

    public struct PlayOptions: CustomStringConvertible {
        public var len:Double = 0
        public var offset:Double = 0
        public var oldStreamName:String = ""
        public var start:Double = 0
        public var streamName:String = ""
        public var transition:PlayTransitions = .Switch
        
        public var description:String {
            var description:String = "RTMPStreamPlayOptions{"
            description += "len:\(len),"
            description += "offset:\(offset),"
            description += "oldStreamName:\(oldStreamName),"
            description += "start:\(start),"
            description += "streamName:\(streamName),"
            description += "transition:\(transition.rawValue)"
            description += "}"
            return description
        }
    }

    static let defaultID:UInt32 = 0
    public static let defaultAudioBitrate:UInt32 = AACEncoder.defaultBitrate
    public static let defaultVideoBitrate:UInt32 = AVCEncoder.defaultBitrate

    public var objectEncoding:UInt8 = RTMPConnection.defaultObjectEncoding

    public var torch:Bool {
        get {
            return captureManager.torch
        }
        set {
            captureManager.torch = newValue
        }
    }

    public var syncOrientation:Bool {
        get {
            return captureManager.syncOrientation
        }
        set {
            captureManager.syncOrientation = newValue
        }
    }

    private var _view:UIView? = nil
    public var view:UIView! {
        if (_view == nil) {
            layer.videoGravity = videoGravity
            captureManager.layer.videoGravity = videoGravity
            _view = UIView()
            _view!.backgroundColor = UIColor.blackColor()
            _view!.layer.addSublayer(captureManager.layer)
            _view!.layer.addSublayer(layer)
            _view!.addObserver(self, forKeyPath: "frame", options: NSKeyValueObservingOptions.New, context: nil)
        }
        return _view!
    }

    public var videoGravity:String! = AVLayerVideoGravityResizeAspectFill {
        didSet {
            layer.videoGravity = videoGravity
            captureManager.layer.videoGravity = videoGravity
        }
    }

    public var audioSettings:[String: AnyObject] {
        get {
            return muxer.audioSettings
        }
        set {
            muxer.audioSettings = newValue
        }
    }

    public var videoSettings:[String: AnyObject] {
        get {
            return muxer.videoSettings
        }
        set {
            muxer.videoSettings = newValue
        }
    }

    public var captureSettings:[String: AnyObject] {
        get {
            return captureManager.dictionaryWithValuesForKeys(AVCaptureSessionManager.supportedSettingsKeys)
        }
        set {
            captureManager.setValuesForKeysWithDictionary(newValue)
        }
    }

    var id:UInt32 = RTMPStream.defaultID
    var readyState:ReadyState = .Initilized {
        didSet {
            switch readyState {
            case .Publishing:
                send("@setDataFrame", arguments: "onMetaData", muxer.createMetadata())
                captureManager.audioDataOutput.setSampleBufferDelegate(muxer.audioEncoder, queue: muxer.audioEncoder.lockQueue)
                captureManager.videoDataOutput.setSampleBufferDelegate(muxer.videoEncoder, queue: muxer.videoEncoder.lockQueue)
            case .Closed:
                captureManager.audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
                captureManager.videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            default:
                break
            }
        }
    }
    
    var readyForKeyframe:Bool = false
    var audioFormatDescription:CMAudioFormatDescriptionRef?
    var videoFormatDescription:CMVideoFormatDescriptionRef?

    private var audioTimestamp:Double = 0
    private var videoTimestamp:Double = 0
    private var rtmpConnection:RTMPConnection
    private var chunkTypes:[FLVTag.TagType:Bool] = [:]
    private lazy var layer:AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private lazy var muxer:RTMPMuxer = RTMPMuxer()
    private var captureManager:AVCaptureSessionManager = AVCaptureSessionManager()
    private let lockQueue:dispatch_queue_t = dispatch_queue_create("com.github.shogo4405.lf.RTMPStream.lock", DISPATCH_QUEUE_SERIAL)

    public init(rtmpConnection: RTMPConnection) {
        self.rtmpConnection = rtmpConnection
        super.init()
        rtmpConnection.addEventListener(Event.RTMP_STATUS, selector: "rtmpStatusHandler:", observer: self)
        if (rtmpConnection.connected) {
            rtmpConnection.createStream(self)
        }
    }

    deinit {
        _view?.removeObserver(self, forKeyPath: "frame")
    }

    public func attachAudio(audio:AVCaptureDevice?) {
        captureManager.attachAudio(audio)
    }

    public func attachCamera(camera:AVCaptureDevice?) {
        captureManager.attachCamera(camera)
        if (readyState == .Publishing) {
            captureManager.videoDataOutput.setSampleBufferDelegate(muxer.videoEncoder, queue: muxer.videoEncoder.lockQueue)
        }
        captureManager.startRunning()
    }

    public func receiveAudio(flag:Bool) {
        dispatch_async(lockQueue) {
            if (self.readyState != .Playing) {
                return
            }
            self.rtmpConnection.doWrite(RTMPChunk(message: RTMPCommandMessage(
                streamId: self.id,
                transactionId: 0,
                objectEncoding: self.objectEncoding,
                commandName: "receiveAudio",
                commandObject: nil,
                arguments: [flag]
            )))
        }
    }
    
    public func receiveVideo(flag:Bool) {
        dispatch_async(lockQueue) {
            if (self.readyState != .Playing) {
                return
            }
            self.rtmpConnection.doWrite(RTMPChunk(message: RTMPCommandMessage(
                streamId: self.id,
                transactionId: 0,
                objectEncoding: self.objectEncoding,
                commandName: "receiveVideo",
                commandObject: nil,
                arguments: [flag]
            )))
        }
    }
    
    public func play(arguments:Any?...) {
        dispatch_async(lockQueue) {
            while (self.readyState == .Initilized) {
                usleep(100)
            }
            self.readyForKeyframe = false
            self.rtmpConnection.doWrite(RTMPChunk(message: RTMPCommandMessage(
                streamId: self.id,
                transactionId: 0,
                objectEncoding: self.objectEncoding,
                commandName: "play",
                commandObject: nil,
                arguments: arguments
            )))
        }
    }
    
    public func publish(name:String?) {
        self.publish(name, type: "live")
    }
    
    public func seek(offset:Double) {
        dispatch_async(lockQueue) {
            if (self.readyState != .Playing) {
                return
            }
            self.rtmpConnection.doWrite(RTMPChunk(message: RTMPCommandMessage(
                streamId: self.id,
                transactionId: 0,
                objectEncoding: self.objectEncoding,
                commandName: "seek",
                commandObject: nil,
                arguments: [offset]
            )))
        }
    }
    
    public func publish(name:String?, type:String) {
        dispatch_async(lockQueue) {
            if (name == nil) {
                return
            }
            
            while (self.readyState == .Initilized) {
                usleep(100)
            }

            self.muxer.dispose()
            self.muxer.delegate = self
            self.captureManager.startRunning()
            self.chunkTypes.removeAll(keepCapacity: false)
            self.rtmpConnection.doWrite(RTMPChunk(
                type: .Zero,
                streamId: RTMPChunk.audio,
                message: RTMPCommandMessage(
                    streamId: self.id,
                    transactionId: 0,
                    objectEncoding: self.objectEncoding,
                    commandName: "publish",
                    commandObject: nil,
                    arguments: [name!, type]
            )))
            
            self.readyState = .Publish
        }
    }
    
    public func close() {
        dispatch_async(lockQueue) {
            if (self.readyState == .Closed) {
                return
            }
            self.rtmpConnection.doWrite(RTMPChunk(
                type: .Zero,
                streamId: RTMPChunk.audio,
                message: RTMPCommandMessage(
                    streamId: self.id,
                    transactionId: 0,
                    objectEncoding: self.objectEncoding,
                    commandName: "deleteStream",
                    commandObject: nil,
                    arguments: [self.id]
            )))
            self.readyState = .Closed
        }
    }
    
    public func send(handlerName:String, arguments:Any?...) {
        if (readyState == .Closed) {
            return
        }
        rtmpConnection.doWrite(RTMPChunk(message: RTMPDataMessage(
            streamId: id,
            objectEncoding: objectEncoding,
            handlerName: handlerName,
            arguments: arguments
        )))
    }

    public func setPointOfInterest(focus: CGPoint, exposure:CGPoint) {
        captureManager.focusPointOfInterest = focus
        captureManager.exposurePointOfInterest = exposure
    }

    func sampleOutput(muxer:RTMPMuxer, audio buffer:NSData, timestamp:Double) {
        let type:FLVTag.TagType = .Audio
        rtmpConnection.doWrite(RTMPChunk(
            type: chunkTypes[type] == nil ? .Zero : .One,
            streamId: type.streamId,
            message: type.createMessage(id, timestamp: UInt32(audioTimestamp), buffer: buffer)
        ))
        chunkTypes[type] = true
        audioTimestamp = timestamp + (audioTimestamp - floor(audioTimestamp))
    }

    func sampleOutput(muxer:RTMPMuxer, video buffer:NSData, timestamp:Double) {
        let type:FLVTag.TagType = .Video
        rtmpConnection.doWrite(RTMPChunk(
            type: chunkTypes[type] == nil ? .Zero : .One,
            streamId: type.streamId,
            message: type.createMessage(id, timestamp: UInt32(videoTimestamp), buffer: buffer)
        ))
        chunkTypes[type] = true
        videoTimestamp = timestamp + (videoTimestamp - floor(videoTimestamp))
    }

    func enqueueSampleBuffer(audio sampleBuffer:CMSampleBuffer) {
    }

    func enqueueSampleBuffer(video sampleBuffer:CMSampleBuffer) {
        dispatch_async(dispatch_get_main_queue()) {
            if (self.readyForKeyframe && self.layer.readyForMoreMediaData) {
                self.layer.enqueueSampleBuffer(sampleBuffer)
                self.layer.setNeedsDisplay()
            }
        }
    }

    func rtmpStatusHandler(notification:NSNotification) {
        let e:Event = Event.from(notification)
        if let data:ECMAObject = e.data as? ECMAObject {
            if let code:String = data["code"] as? String {
                switch code {
                case "NetConnection.Connect.Success":
                    readyState = .Initilized
                    rtmpConnection.createStream(self)
                case "NetStream.Publish.Start":
                    readyState = .Publishing
                default:
                    break
                }
            }
        }
    }

    override public func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        guard let keyPath:String = keyPath else {
            return
        }
        switch keyPath {
        case "frame":
            layer.frame = view.bounds
            captureManager.layer.frame = view.bounds
        default:
            break
        }
    }
}