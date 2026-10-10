# flutter_webrtc 1.6.2+hotfix.1: Flutter's texture registry may wait for
# copyPixelBuffer on the raster thread. Never call it holding _lock.
def patch_webrtc_renderer(path)
  source = File.read(path)
  return if source.include?('// Ligament: unregister outside the pixel buffer lock.')
  original = <<~'OBJC'
    - (void)dispose {
      [_eventChannel setStreamHandler:nil];
      _eventChannel = nil;
      os_unfair_lock_lock(&_lock);
      [_registry unregisterTexture:_textureId];
      _textureId = -1;
      if (_pixelBufferRef) {
        CVBufferRelease(_pixelBufferRef);
        _pixelBufferRef = nil;
      }
      _frameAvailable = false;
      os_unfair_lock_unlock(&_lock);
    }
  OBJC
  replacement = <<~'OBJC'
    - (void)dispose {
      // Ligament: unregister outside the pixel buffer lock.
      self.videoTrack = nil;
      [_eventChannel setStreamHandler:nil];
      _eventChannel = nil;
      os_unfair_lock_lock(&_lock);
      int64_t textureId = _textureId;
      _textureId = -1;
      CVPixelBufferRef buffer = _pixelBufferRef;
      _pixelBufferRef = nil;
      _frameAvailable = false;
      os_unfair_lock_unlock(&_lock);
      if (textureId != -1) [_registry unregisterTexture:textureId];
      if (buffer) CVBufferRelease(buffer);
    }
  OBJC
  raise 'flutter_webrtc renderer changed; review the texture lock patch' unless source.include?(original)
  source = source.sub(original, replacement)
  notify = '      [_registry textureFrameAvailable:_textureId];'
  raise 'flutter_webrtc frame notification changed' unless source.include?(notify)
  source = source.sub(notify, <<~'OBJC'.rstrip)
          dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_textureId != -1) {
              [self->_registry textureFrameAvailable:self->_textureId];
            }
          });
  OBJC
  File.write(path, source)
end
