//
//  CDYViewController.m
//  SimpleRemoteIO
//
//  Created by danny on 2014/4/14.
//  Copyright (c) 2014年 danny. All rights reserved.
//

#import "CDYViewController.h"
#import <AVFoundation/AVFoundation.h>


//需带耳机运行本例，否则会有回声(啸音)
@interface CDYViewController ()
{
    AVAudioSession *audioSession;
    AUGraph auGraph;
    AudioUnit remoteIOUnit;
    AUNode remoteIONode;
    AURenderCallbackStruct inputProc;
    BOOL isMute;
    
}

@end

@implementation CDYViewController


//依照Apple提供的结果，PerformThru以C语言的Static Function存在的，所以放在上端
//对声音更复杂的处理在PerformThru中完成，本例仅做静音处理
static OSStatus	PerformThru(
                            void						*inRefCon,
                            AudioUnitRenderActionFlags 	*ioActionFlags,
                            const AudioTimeStamp 		*inTimeStamp,
                            UInt32 						inBusNumber,
                            UInt32 						inNumberFrames,
                            AudioBufferList 			*ioData)
{
    //界面的指针，用来获取静音开关按钮
    CDYViewController *THIS=(__bridge CDYViewController*)inRefCon;
    //AudioUnitRender将Remote I/O的输入端数据读进来，其中每次数据是以Frame存在的，
    //每笔Frame有N笔音讯数据内容(这与类比转数位的概念有关，在此会以每笔Frame有N点)，2声道就是乘上2倍的数据量，
    //整个数据都存在例子中的ioData指针中
    OSStatus renderErr = AudioUnitRender(THIS->remoteIOUnit, ioActionFlags,
                                         inTimeStamp, 1, inNumberFrames, ioData);
    //如果静音开关打开
    if (THIS->isMute == YES){
        //清零所有声道的数据 mNumberBuffers为声道个数 双声道为0~1，单声道索引就只有0
        for (UInt32 i=0; i < ioData->mNumberBuffers; i++)
        {
           // ioData->mBuffers[i].mData 声音数据
          // ioData->mBuffers[i].mDataByteSize 声音数据长度 Apple一般会提供1024
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
    }
    
    if (renderErr < 0) {
        return renderErr;
    }
    
    
    return noErr;
}




//
- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    isMute = NO;
    [self initRemoteIO];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


- (void) initRemoteIO
{
    // AudioSession，它管理与取得Audio硬体的资讯，并且单例形式存在 在上篇《oc开发笔记1 录音和播放》有介绍
    audioSession = [AVAudioSession sharedInstance];
    
    NSError *error;
    // set Category for Play and Record
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error];
    [audioSession setPreferredSampleRate:(double)44100.0 error:&error];
    [audioSession setPreferredIOBufferDuration:(double)32.0/44100.0 error:&error];
    //Audio Processing Graph(AUGraph)将多个输入声音进行混合，以及需要处理音讯资料时可以加入一个render的回调(callback)，
    //本例中是对声音进行静音处理
    // 完成后需要像开档案一样开启它，这里使用AUGraphOpen，接下来就可以开始使用AUGraph相关设定，在使用与AUGraph有关时会在命名前面加上AUGraph，像是：
    //    AUGraphSetNodeInputCallback 设定回呼时会被呼叫的Function
    //    AUGraphInitialize 初始化AUGraph
    //    AUGraphUpdate 更新AUGraph，当有增加Node或移除时可以执行这将整个AUGraph规则更新
    //    AUGraphStart 所有设定都无误要开始执行AUGraph功能。
    
    CheckError (NewAUGraph(&auGraph),"couldn't NewAUGraph");
    CheckError(AUGraphOpen(auGraph),"couldn't AUGraphOpen");
    ////    typedef struct AudioComponentDescription {
    //        /*一个音频组件的通用的独特的四字节码标识*/
    //        OSType              componentType;
    //        /*根据componentType设置相应的类型*/
    //        OSType              componentSubType;
    //        /*厂商的身份验证*/
    //        OSType              componentManufacturer;
    //        /*如果没有一个明确指定的值，那么它必须被设置为0*/
    //        UInt32              componentFlags;
    //        /*如果没有一个明确指定的值，那么它必须被设置为0*/
    //        UInt32              componentFlagsMask;
    //    } AudioComponentDescription;
    AudioComponentDescription componentDesc;
    componentDesc.componentType = kAudioUnitType_Output;
    componentDesc.componentSubType = kAudioUnitSubType_RemoteIO;
    componentDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    componentDesc.componentFlags = 0;
    componentDesc.componentFlagsMask = 0;
    //AUGraph中必需要加入功能性的Node才能完成
    //加入成功后利用Node的资料来取得这个Node的Audio Unit元件，对於Node中的一些细项设定必需要靠取得的Audio Unit元件来设定。
    //前面Remote I/O Unit中看到利用AudioUnitSetProperty设定时必需要指定你要哪个Audio Unit，每一个Node都是一个Audio Unit，
    //都能对它做各别的设定，设定的方式是一样的，但参数不一定相同，像在设定kAudioUnitType_Mixer时，可以设定它输入要几个Channel
    CheckError (AUGraphAddNode(auGraph,&componentDesc,&remoteIONode),"couldn't add remote io node");
    CheckError(AUGraphNodeInfo(auGraph,remoteIONode,NULL,&remoteIOUnit),"couldn't get remote io unit from node");
    
    //set BUS Remote I/O Unit是属於Audio Unit其中之一，也是与硬体有关的一个Unit，它分为输出端与输入端，输入端通常为 麦克风 ，输出端为 喇叭、耳机 …等
    //将Element 0的Output scope与喇叭接上，Element 1的Input scope与麦克风接上
    //然后通过AUGraph把Element 0和Element 1接上
    UInt32 oneFlag = 1;
    UInt32 busZero = 0;
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output,
                                    busZero,
                                    &oneFlag,
                                    sizeof(oneFlag)),"couldn't kAudioOutputUnitProperty_EnableIO with kAudioUnitScope_Output");
    //
    UInt32 busOne = 1;
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Input,
                                    busOne,
                                    &oneFlag,
                                    sizeof(oneFlag)),"couldn't kAudioOutputUnitProperty_EnableIO with kAudioUnitScope_Input");
    //音频流描述AudioStreamBasicDescription
    AudioStreamBasicDescription effectDataFormat;
    UInt32 propSize = sizeof(effectDataFormat);
    CheckError(AudioUnitGetProperty(remoteIOUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    0,
                                    &effectDataFormat,
                                    &propSize),"couldn't get kAudioUnitProperty_StreamFormat with kAudioUnitScope_Output");
    
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    1,
                                    &effectDataFormat,
                                    propSize),"couldn't set kAudioUnitProperty_StreamFormat with kAudioUnitScope_Output");
    
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input,
                                    0,
                                    &effectDataFormat,
                                    propSize),"couldn't set kAudioUnitProperty_StreamFormat with kAudioUnitScope_Input");
    
    
    //当我们都将硬体与软体都设定完成后，接下来就要在音声音数据进来时设定一个Callback，
    //让每次音讯资料从硬体转成数位资料时都能直接呼叫Callbackle立即处理这些数位资料后再输出至输出端，
    //本例中设置为PerformThru，其定义在文章开始的地方
    inputProc.inputProc = PerformThru;
    //把self传给PerformThru，以获取开关按钮
    inputProc.inputProcRefCon = (__bridge void *)(self);
     //  AUGraphSetNodeInputCallback 设定回呼时会被呼叫的Function
    CheckError(AUGraphSetNodeInputCallback(auGraph, remoteIONode, 0, &inputProc),"Error setting io output callback");
    //    AUGraphInitialize 初始化AUGraph
    CheckError(AUGraphInitialize(auGraph),"couldn't AUGraphInitialize" );
      //    AUGraphUpdate 更新AUGraph，当有增加Node或移除时可以执行这将整个AUGraph规则更新
    CheckError(AUGraphUpdate(auGraph, NULL),"couldn't AUGraphUpdate" );
    //    AUGraphStart 所有设定都无误要开始执行AUGraph功能。
    CheckError(AUGraphStart(auGraph),"couldn't AUGraphStart");
    //
    CAShow(auGraph);
}

//
static void CheckError(OSStatus error, const char *operation)
{
    if (error == noErr) return;
    
    char str[20];
    // see if it appears to be a 4-char-code
    *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else
        // no, format it as an integer
        sprintf(str, "%d", (int)error);
    
    fprintf(stderr, "Error: %s (%s)\n", operation, str);
    
    exit(1);
}
//开关按钮的动作处理函数
- (IBAction)isMute:(id)sender {
    
    UISwitch *swIsMute = (UISwitch*) sender;
    
    isMute = swIsMute.isOn;
}
@end
