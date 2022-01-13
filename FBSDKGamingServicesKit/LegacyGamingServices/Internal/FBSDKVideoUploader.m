// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "FBSDKVideoUploader.h"

#import <Foundation/Foundation.h>

#import "FBSDKGamingServicesCoreKitImport.h"

#define FBSDK_GAMING_RESULT_COMPLETION_GESTURE_KEY @"completionGesture"
#define FBSDK_GAMING_RESULT_COMPLETION_GESTURE_VALUE_POST @"post"
#define FBSDK_GAMING_VIDEO_END_OFFSET @"end_offset"
#define FBSDK_GAMING_VIDEO_FILE_CHUNK @"video_file_chunk"
#define FBSDK_GAMING_VIDEO_ID @"video_id"
#define FBSDK_GAMING_VIDEO_SIZE @"file_size"
#define FBSDK_GAMING_VIDEO_START_OFFSET @"start_offset"
#define FBSDK_GAMING_VIDEO_UPLOAD_PHASE @"upload_phase"
#define FBSDK_GAMING_VIDEO_UPLOAD_PHASE_FINISH @"finish"
#define FBSDK_GAMING_VIDEO_UPLOAD_PHASE_START @"start"
#define FBSDK_GAMING_VIDEO_UPLOAD_PHASE_TRANSFER @"transfer"
#define FBSDK_GAMING_VIDEO_UPLOAD_SESSION_ID @"upload_session_id"
#define FBSDK_GAMING_VIDEO_UPLOAD_SUCCESS @"success"

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0

static NSErrorDomain const FBSDKGamingVideoUploadErrorDomain = @"com.facebook.sdk.gaming.videoupload";

#else

static NSString *const FBSDKGamingVideoUploadErrorDomain = @"com.facebook.sdk.gaming.videoupload";

#endif

static NSString *const FBSDKVideoUploaderDefaultGraphNode = @"me";
static NSString *const FBSDKVideoUploaderEdge = @"videos";

@implementation FBSDKVideoUploader
{
  NSNumber *_videoID;
  NSNumber *_uploadSessionID;
  NSNumberFormatter *_numberFormatter;
  NSString *_graphPath;
  NSString *_videoName;
  NSUInteger _videoSize;
}

#pragma mark Public Method
- (instancetype)initWithVideoName:(NSString *)videoName videoSize:(NSUInteger)videoSize parameters:(NSDictionary *)parameters delegate:(id<FBSDKVideoUploaderDelegate>)delegate
{
  self = [super init];
  if (self) {
    _parameters = [parameters copy];
    _delegate = delegate;
    _graphNode = FBSDKVideoUploaderDefaultGraphNode;
    _videoName = videoName;
    _videoSize = videoSize;
  }
  return self;
}

- (void)start
{
  _graphPath = [self _graphPathWithSuffix:FBSDKVideoUploaderEdge, nil];
  [self _postStartRequest];
}

#pragma mark Helper Method

- (void)_postStartRequest
{
  FBSDKGraphRequestCompletion startRequestCompletionHandler = ^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
    if (error) {
      [self.delegate videoUploader:self didFailWithError:error];
      return;
    } else {
      result = [self dictionaryValue:result];
      NSNumber *uploadSessionID = [self.numberFormatter numberFromString:result[FBSDK_GAMING_VIDEO_UPLOAD_SESSION_ID]];
      NSNumber *videoID = [self.numberFormatter numberFromString:result[FBSDK_GAMING_VIDEO_ID]];
      NSDictionary *offsetDictionary = [self _extractOffsetsFromResultDictionary:result];
      if (uploadSessionID == nil || videoID == nil) {
        [self.delegate videoUploader:self didFailWithError:
         [FBSDKError errorWithDomain:FBSDKGamingVideoUploadErrorDomain
                                code:0
                             message:@"Failed to get valid upload_session_id or video_id."]];
        return;
      } else if (offsetDictionary == nil) {
        return;
      }
      self->_uploadSessionID = uploadSessionID;
      self->_videoID = videoID;
      [self _startTransferRequestWithOffsetDictionary:offsetDictionary];
    }
  };
  if (_videoSize == 0) {
    [self.delegate videoUploader:self didFailWithError:
     [FBSDKError errorWithDomain:FBSDKGamingVideoUploadErrorDomain
                            code:0
                         message:[NSString stringWithFormat:@"Invalid video size: %lu", (unsigned long)_videoSize]]];
    return;
  }
  [[[FBSDKGraphRequest alloc] initWithGraphPath:_graphPath
                                     parameters:@{
      FBSDK_GAMING_VIDEO_UPLOAD_PHASE : FBSDK_GAMING_VIDEO_UPLOAD_PHASE_START,
      FBSDK_GAMING_VIDEO_SIZE : [NSString stringWithFormat:@"%tu", _videoSize],
    }
                                     HTTPMethod:@"POST"] startWithCompletion:startRequestCompletionHandler];
}

- (void)_startTransferRequestWithOffsetDictionary:(NSDictionary *)offsetDictionary
{
  NSUInteger startOffset = [offsetDictionary[FBSDK_GAMING_VIDEO_START_OFFSET] unsignedIntegerValue];
  NSUInteger endOffset = [offsetDictionary[FBSDK_GAMING_VIDEO_END_OFFSET] unsignedIntegerValue];
  if (startOffset == endOffset) {
    [self _postFinishRequest];
    return;
  } else {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      size_t chunkSize = (unsigned long)(endOffset - startOffset);
      NSData *data = [self.delegate videoChunkDataForVideoUploader:self startOffset:startOffset endOffset:endOffset];
      if (data == nil || data.length != chunkSize) {
        [self.delegate videoUploader:self didFailWithError:
         [FBSDKError errorWithDomain:FBSDKGamingVideoUploadErrorDomain
                                code:0
                             message:[NSString
                                      stringWithFormat:@"Fail to get video chunk with start offset: %lu, end offset : %lu.",
                                      (unsigned long)startOffset,
                                      (unsigned long)endOffset]]];
        return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        FBSDKGraphRequestDataAttachment *dataAttachment = [[FBSDKGraphRequestDataAttachment alloc] initWithData:data
                                                                                                       filename:self->_videoName
                                                                                                    contentType:@""];
        FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc] initWithGraphPath:self->_graphPath
                                                                       parameters:@{
                                        FBSDK_GAMING_VIDEO_UPLOAD_PHASE : FBSDK_GAMING_VIDEO_UPLOAD_PHASE_TRANSFER,
                                        FBSDK_GAMING_VIDEO_START_OFFSET : offsetDictionary[FBSDK_GAMING_VIDEO_START_OFFSET],
                                        FBSDK_GAMING_VIDEO_UPLOAD_SESSION_ID : self->_uploadSessionID,
                                        FBSDK_GAMING_VIDEO_FILE_CHUNK : dataAttachment,
                                      }
                                                                       HTTPMethod:@"POST"];
        [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *innerError) {
          if (innerError) {
            [self.delegate videoUploader:self didFailWithError:innerError];
            return;
          }
          NSDictionary *innerOffsetDictionary = [self _extractOffsetsFromResultDictionary:result];
          if (innerOffsetDictionary == nil) {
            return;
          }
          [self _startTransferRequestWithOffsetDictionary:innerOffsetDictionary];
        }];
      });
    });
  }
}

- (void)_postFinishRequest
{
  NSMutableDictionary *parameters = [NSMutableDictionary new];
  parameters[FBSDK_GAMING_VIDEO_UPLOAD_PHASE] = FBSDK_GAMING_VIDEO_UPLOAD_PHASE_FINISH;
  if (_uploadSessionID != nil) {
    parameters[FBSDK_GAMING_VIDEO_UPLOAD_SESSION_ID] = _uploadSessionID;
  }
  [parameters addEntriesFromDictionary:self.parameters];
  [[[FBSDKGraphRequest alloc] initWithGraphPath:_graphPath
                                     parameters:parameters
                                     HTTPMethod:@"POST"] startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
                                       if (error) {
                                         [self.delegate videoUploader:self didFailWithError:error];
                                       } else {
                                         result = [self dictionaryValue:result];
                                         if (result[FBSDK_GAMING_VIDEO_UPLOAD_SUCCESS] == nil) {
                                           [self.delegate videoUploader:self didFailWithError:
                                            [FBSDKError errorWithDomain:FBSDKGamingVideoUploadErrorDomain
                                                                   code:0
                                                                message:@"Failed to finish uploading."]];
                                           return;
                                         }
                                         NSMutableDictionary *shareResult = [NSMutableDictionary new];
                                         if (result[FBSDK_GAMING_VIDEO_UPLOAD_SUCCESS]) {
                                           shareResult[FBSDK_GAMING_VIDEO_UPLOAD_SUCCESS] = result[FBSDK_GAMING_VIDEO_UPLOAD_SUCCESS];
                                         }

                                         shareResult[FBSDK_GAMING_RESULT_COMPLETION_GESTURE_KEY] = FBSDK_GAMING_RESULT_COMPLETION_GESTURE_VALUE_POST;

                                         if (self->_videoID != nil) {
                                           shareResult[FBSDK_GAMING_VIDEO_ID] = self->_videoID;
                                         }

                                         [self.delegate videoUploader:self didCompleteWithResults:shareResult];
                                       }
                                     }];
}

- (NSDictionary *)_extractOffsetsFromResultDictionary:(id)result
{
  result = [self dictionaryValue:result];
  NSNumber *startNum = [self.numberFormatter numberFromString:result[FBSDK_GAMING_VIDEO_START_OFFSET]];
  NSNumber *endNum = [self.numberFormatter numberFromString:result[FBSDK_GAMING_VIDEO_END_OFFSET]];
  if (startNum == nil || endNum == nil) {
    [self.delegate videoUploader:self didFailWithError:
     [FBSDKError errorWithDomain:FBSDKGamingVideoUploadErrorDomain
                            code:0
                         message:@"Fail to get valid start_offset or end_offset."]];
    return nil;
  }
  if ([startNum compare:endNum] == NSOrderedDescending) {
    [self.delegate videoUploader:self didFailWithError:
     [FBSDKError errorWithDomain:FBSDKGamingVideoUploadErrorDomain
                            code:0
                         message:@"Invalid offset: start_offset is greater than end_offset."]];
    return nil;
  }

  NSMutableDictionary *shareResults = [NSMutableDictionary new];

  if (startNum != nil) {
    shareResults[FBSDK_GAMING_VIDEO_START_OFFSET] = startNum;
  }

  if (endNum != nil) {
    shareResults[FBSDK_GAMING_VIDEO_END_OFFSET] = endNum;
  }

  return shareResults;
}

- (NSNumberFormatter *)numberFormatter
{
  if (!_numberFormatter) {
    _numberFormatter = [NSNumberFormatter new];
    _numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
  }
  return _numberFormatter;
}

- (NSString *)_graphPathWithSuffix:(NSString *)suffix, ... NS_REQUIRES_NIL_TERMINATION
{
  NSMutableString *graphPath = [[NSMutableString alloc] initWithString:self.graphNode];
  va_list args;
  va_start(args, suffix);
  for (NSString *arg = suffix; arg != nil; arg = va_arg(args, NSString *)) {
    [graphPath appendFormat:@"/%@", arg];
  }
  va_end(args);
  return graphPath;
}

- (NSDictionary *)dictionaryValue:(id)object
{
  return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

@end
