//
//  CallProcessor.swift
//  NotificationServiceExtension
//
//  Created by huangfeng on 2024/6/6.
//  Copyright © 2024 Fin. All rights reserved.
//

import AudioToolbox
import AVFAudio
import Foundation

let kBarkSoundPrefix = "bark.sounds.30s"

class CallProcessor: NotificationContentProcessor {
    /// 震动完毕后，返回的 content
    var content: UNMutableNotificationContent? = nil
    /// 是否需要停止震动，由主APP发出停止通知时赋值
    var shouldStopVibration = false
    /// 铃声文件夹，扩展访问不到主APP中的铃声，需要先共享铃声文件
    let soundsDirectoryUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bark")?.appendingPathComponent("Sounds")
    
    func process(identifier: String, content bestAttemptContent: UNMutableNotificationContent) async throws -> UNMutableNotificationContent {
        guard let call = bestAttemptContent.userInfo["call"] as? String, call == "1" else {
            return bestAttemptContent
        }
        self.content = bestAttemptContent
        
        // 延长铃声到30s
        self.processNotificationSound()
        // 注册停止震动通知
        self.registerObserver()
        // 开始震动
        await startVibrate()
        
        return bestAttemptContent
    }
    
    func serviceExtensionTimeWillExpire(contentHandler: (UNNotificationContent) -> Void) {
        shouldStopVibration = true
        if let content {
            contentHandler(content)
        }
    }
        
    deinit {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = CFNotificationName(kStopCallProcessorKey as CFString)
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, name, nil)
    }
}

// MARK: - 铃声

extension CallProcessor {
    // 将通知铃声延长到30s，并用30s的长铃声替换掉原铃声
    func processNotificationSound() {
        guard let content else {
            return
        }
        let sound = ((content.userInfo["aps"] as? [String: Any])?["sound"] as? String)?.split(separator: ".")
        let soundName: String
        let soundType: String
        if sound?.count == 2, let first = sound?.first, let last = sound?.last, last == "caf" {
            soundName = String(first)
            soundType = String(last)
        } else {
            soundName = "multiwayinvitation"
            soundType = "caf"
        }
        
        if let longSoundUrl = getLongSound(soundName: soundName, soundType: soundType) {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: longSoundUrl.lastPathComponent))
        }
    }
    
    func getLongSound(soundName: String, soundType: String) -> URL? {
        guard let soundsDirectoryUrl else {
            return nil
        }
        
        // 已经存在处理过的长铃声，则直接返回
        let longSoundName = "\(kBarkSoundPrefix).\(soundName).\(soundType)"
        let longSoundPath = soundsDirectoryUrl.appendingPathComponent(longSoundName)
        if FileManager.default.fileExists(atPath: longSoundPath.path) {
            return longSoundPath
        }
        
        // 原始铃声路径
        var path: String = soundsDirectoryUrl.appendingPathComponent("\(soundName).\(soundType)").path
        if !FileManager.default.fileExists(atPath: path) {
            // 不存在自定义的铃声，就用内置的铃声
            path = Bundle.main.path(forResource: soundName, ofType: soundType) ?? ""
        }
        guard !path.isEmpty else {
            return nil
        }
        
        // 将原始铃声处理成30s的长铃声，并缓存起来
        return mergeCAFFilesToDuration(inputFile: URL(fileURLWithPath: path))
    }

    /// - Author: @uuneo
    /// - Description:将输入的音频文件重复为指定时长的音频文件
    /// - Parameters:
    ///   - inputFile: 原始铃声文件路径
    ///   - targetDuration: 重复的时长
    /// - Returns: 长铃声文件路径
    func mergeCAFFilesToDuration(inputFile: URL, targetDuration: TimeInterval = 30) -> URL? {
        guard let soundsDirectoryUrl else {
            return nil
        }
        let longSoundName = "\(kBarkSoundPrefix).\(inputFile.lastPathComponent)"
        let longSoundPath = soundsDirectoryUrl.appendingPathComponent(longSoundName)
        
        do {
            // 打开输入文件并获取音频格式
            let audioFile = try AVAudioFile(forReading: inputFile)
            let audioFormat = audioFile.processingFormat
            let sampleRate = audioFormat.sampleRate

            // 计算目标帧数
            let targetFrames = AVAudioFramePosition(targetDuration * sampleRate)
            var currentFrames: AVAudioFramePosition = 0

            // 创建输出音频文件
            let outputAudioFile = try AVAudioFile(forWriting: longSoundPath, settings: audioFormat.settings)
            
            // 循环读取文件数据，拼接到目标时长
            while currentFrames < targetFrames {
                // 每次读取整个文件的音频数据
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                    // 出错了就终止，避免死循环
                    return nil
                }
                
                try audioFile.read(into: buffer)

                // 计算剩余所需帧数
                let remainingFrames = targetFrames - currentFrames
                if AVAudioFramePosition(buffer.frameLength) > remainingFrames {
                    // 如果当前缓冲区帧数超出所需，截取剩余部分
                    let truncatedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(remainingFrames))!
                    let channelCount = Int(buffer.format.channelCount)
                    for channel in 0..<channelCount {
                        let sourcePointer = buffer.floatChannelData![channel]
                        let destinationPointer = truncatedBuffer.floatChannelData![channel]
                        memcpy(destinationPointer, sourcePointer, Int(remainingFrames) * MemoryLayout<Float>.size)
                    }
                    truncatedBuffer.frameLength = AVAudioFrameCount(remainingFrames)
                    try outputAudioFile.write(from: truncatedBuffer)
                    break
                } else {
                    // 否则写入整个缓冲区
                    try outputAudioFile.write(from: buffer)
                    currentFrames += AVAudioFramePosition(buffer.frameLength)
                }
                
                // 重置输入文件读取位置
                audioFile.framePosition = 0
            }
            return longSoundPath
        } catch {
            print("Error processing CAF file: \(error)")
            return nil
        }
    }
}

// MARK: - 震动

extension CallProcessor {
    // 开始手机震动
    private func startVibrate() async {
        guard shouldStopVibration == false else {
            return
        }
        // 播放震动
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        // 震动间隔
        try? await Task.sleep(nanoseconds: 2 * 1000000000)
        await startVibrate()
    }
    
    /// 注册停止通知
    func registerObserver() {
        let notification = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(notification, observer, { _, pointer, _, _, _ in
            guard let observer = pointer else { return }
            let processor = Unmanaged<CallProcessor>.fromOpaque(observer).takeUnretainedValue()
            processor.shouldStopVibration = true
        }, kStopCallProcessorKey as CFString, nil, .deliverImmediately)
    }
}
