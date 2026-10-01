import AVFoundation
import ImageIO
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
  private let lock = NSLock()
  private var request: StockCaptureRequest?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var firstTime: CMTime?
  private var lastTime: CMTime?
  private var lastSample: CMTime?
  private var inactiveTime: CMTime?
  private var orientation: CGImagePropertyOrientation?
  private var sourceSize: CGSize?
  private var frames = 0
  private var terminal = false

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    lock.lock(); defer { lock.unlock() }
    do {
      let request = try StockCaptureSession.active()
      self.request = request
      guard Date().timeIntervalSince(request.createdAt) <= 300 else {
        throw StockCaptureError.invalid("录屏配置已过期，请重新运行开始快捷指令")
      }
      let folder = try StockCaptureSession.directory(request.id)
      guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording").path) else {
        throw StockCaptureError.invalid("该录屏会话已使用，请重新运行开始快捷指令")
      }
      try Data("recording".utf8).write(to: folder.appendingPathComponent("recording"), options: .atomic)
    } catch { abort(error) }
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    // 盘点截图不需要音轨，麦克风也在系统入口中隐藏。
    guard sampleBufferType == .video else { return }
    lock.lock(); defer { lock.unlock() }
    guard !terminal else { return }
    do {
      guard let request = request, CMSampleBufferDataIsReady(sampleBuffer),
        let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        throw StockCaptureError.invalid("系统录屏没有返回有效画面")
      }
      let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      guard time.isValid, time.isNumeric else { throw StockCaptureError.invalid("录屏时间戳无效") }
      if let checked = lastSample, CMTimeCompare(time, checked) < 0 {
        throw StockCaptureError.invalid("录屏时间戳发生回退，请重新录制")
      }
      if let checked = lastSample, CMTimeGetSeconds(time - checked) < 0.09 { return }
      lastSample = time
      if try StockCaptureSession.hostForeground() {
        inactiveTime = nil
        return
      }
      if inactiveTime == nil { inactiveTime = time }
      // 排除离开助手时的切换动画；不保存助手本身的画面。
      guard let inactiveTime = inactiveTime else { preconditionFailure("录屏切换状态缺失") }
      if CMTimeGetSeconds(time - inactiveTime) < 0.8 { return }
      if let first = firstTime, CMTimeGetSeconds(time - first) > 120 {
        throw StockCaptureError.invalid("录屏超过 120 秒，请分段录制")
      }
      let attached = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
        attachmentModeOut: nil) as? NSNumber
      let current: CGImagePropertyOrientation
      if let attached = attached {
        guard let value = CGImagePropertyOrientation(rawValue: attached.uint32Value) else {
          throw StockCaptureError.invalid("系统录屏方向标记无效")
        }
        current = value
      } else { current = .up } // 系统未标记方向时，像素缓冲自身即为正向。
      let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
      if writer == nil {
        let output = try StockCaptureSession.directory(request.id).appendingPathComponent("capture.mp4")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let scale = min(1, min(1080 / size.width, 2400 / size.height))
        let width = Int(size.width * scale) / 2 * 2
        let height = Int(size.height * scale) / 2 * 2
        guard width >= 100, height >= 100 else { throw StockCaptureError.invalid("录屏分辨率过小") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: width, AVVideoHeightKey: height,
          AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000,
            AVVideoExpectedSourceFrameRateKey: 10, AVVideoMaxKeyFrameIntervalKey: 10],
        ])
        input.expectsMediaDataInRealTime = true
        switch current {
        case .up: input.transform = .identity
        case .down: input.transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case .right: input.transform = CGAffineTransform(translationX: CGFloat(height), y: 0).rotated(by: .pi / 2)
        case .left: input.transform = CGAffineTransform(translationX: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
        default: throw StockCaptureError.invalid("录屏方向包含镜像，请保持正常竖屏录制")
        }
        guard writer.canAdd(input) else { throw StockCaptureError.invalid("无法配置录屏编码器") }
        writer.add(input)
        guard writer.startWriting() else {
          if let error = writer.error { throw error }
          throw StockCaptureError.invalid("无法启动录屏编码")
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer; self.input = input
        firstTime = time; orientation = current; sourceSize = size
      }
      guard sourceSize == size, orientation == current else {
        throw StockCaptureError.invalid("录屏尺寸或方向发生变化，请保持竖屏")
      }
      guard let writer = writer, let input = input else { preconditionFailure("录屏编码状态丢失") }
      guard writer.status == .writing, input.isReadyForMoreMediaData else {
        if let error = writer.error { throw error }
        throw StockCaptureError.invalid("录屏编码器无法及时处理画面，请重新录制")
      }
      guard input.append(sampleBuffer) else {
        if let error = writer.error { throw error }
        throw StockCaptureError.invalid("录屏画面写入失败")
      }
      lastTime = time; frames += 1
    } catch { abort(error) }
  }

  override func broadcastPaused() {
    lock.lock(); defer { lock.unlock() }
    if !terminal { abort(StockCaptureError.invalid("录屏被暂停，请完整重新录制")) }
  }
  override func broadcastFinished() {
    lock.lock()
    guard !terminal else { lock.unlock(); return }
    guard let request = request, let writer = writer, let input = input,
      let first = firstTime, let last = lastTime, frames >= 2 else {
      abort(StockCaptureError.invalid("没有录到盘点单，请确认开始录屏后已切回瑞幸盘"))
      lock.unlock()
      return
    }
    terminal = true
    input.markAsFinished()
    let completion = StockCaptureCompletion(id: request.id, frames: frames,
      duration: CMTimeGetSeconds(last - first))
    lock.unlock()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting {
      defer { finished.signal() }
      do {
        guard writer.status == .completed else {
          if let error = writer.error { throw error }
          throw StockCaptureError.invalid("录屏结束时写入失败")
        }
        try JSONEncoder().encode(completion).write(to: StockCaptureSession.directory(request.id)
          .appendingPathComponent("completed.json"), options: .atomic)
        StockCaptureSession.announce()
      } catch {
        do { try StockCaptureSession.fail(error, id: request.id) }
        catch { preconditionFailure(error.localizedDescription) }
      }
    }
    // 返回结束回调前先落盘完成标记，防止扩展被系统回收时丢失最终结果。
    if finished.wait(timeout: .now() + 5) == .timedOut {
      writer.cancelWriting()
      do { try StockCaptureSession.fail(StockCaptureError.invalid("录屏结束写入超时，请重新录制"), id: request.id) }
      catch { preconditionFailure(error.localizedDescription) }
    }
  }
  private func abort(_ error: Error) {
    terminal = true
    writer?.cancelWriting()
    if let request = request {
      do { try StockCaptureSession.fail(error, id: request.id) }
      catch { preconditionFailure(error.localizedDescription) }
    }
    // 不在持锁状态下调用系统终止接口，避免系统回调重入造成死锁。
    DispatchQueue.main.async { self.finishBroadcastWithError(error) }
  }
}
