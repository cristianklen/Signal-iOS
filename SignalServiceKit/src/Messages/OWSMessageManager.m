//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageManager.h"
#import "AppContext.h"
#import "AppReadiness.h"
#import "ContactsManagerProtocol.h"
#import "MimeTypeUtil.h"
#import "NSNotificationCenter+OWS.h"
#import "NSString+SSK.h"
#import "NotificationsProtocol.h"
#import "OWSAttachmentDownloads.h"
#import "OWSBlockingManager.h"
#import "OWSCallMessageHandler.h"
#import "OWSContact.h"
#import "OWSDevice.h"
#import "OWSDevicesService.h"
#import "OWSDisappearingConfigurationUpdateInfoMessage.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "OWSDisappearingMessagesJob.h"
#import "OWSIdentityManager.h"
#import "OWSIncomingMessageFinder.h"
#import "OWSIncomingSentMessageTranscript.h"
#import "OWSMessageSender.h"
#import "OWSMessageUtils.h"
#import "OWSOutgoingReceiptManager.h"
#import "OWSPrimaryStorage.h"
#import "OWSReadReceiptManager.h"
#import "OWSRecordTranscriptJob.h"
#import "OWSSyncGroupsMessage.h"
#import "OWSSyncGroupsRequestMessage.h"
#import "ProfileManagerProtocol.h"
#import "SSKEnvironment.h"
#import "SSKSessionStore.h"
#import "TSAccountManager.h"
#import "TSAttachment.h"
#import "TSAttachmentPointer.h"
#import "TSAttachmentStream.h"
#import "TSContactThread.h"
#import "TSDatabaseView.h"
#import "TSGroupModel.h"
#import "TSGroupThread.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSQuotedMessage.h"
#import <SignalCoreKit/Cryptography.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalServiceKit/OWSUnknownProtocolVersionMessage.h>
#import <SignalServiceKit/SignalRecipient.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <YapDatabase/YapDatabase.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark -

@implementation OWSMessageManager

- (instancetype)init
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    return self;
}

#pragma mark - Dependencies

- (id<OWSCallMessageHandler>)callMessageHandler
{
    OWSAssertDebug(SSKEnvironment.shared.callMessageHandler);

    return SSKEnvironment.shared.callMessageHandler;
}

- (id<ContactsManagerProtocol>)contactsManager
{
    OWSAssertDebug(SSKEnvironment.shared.contactsManager);

    return SSKEnvironment.shared.contactsManager;
}

- (MessageSenderJobQueue *)messageSenderJobQueue
{
    return SSKEnvironment.shared.messageSenderJobQueue;
}

- (OWSBlockingManager *)blockingManager
{
    OWSAssertDebug(SSKEnvironment.shared.blockingManager);

    return SSKEnvironment.shared.blockingManager;
}

- (OWSIdentityManager *)identityManager
{
    OWSAssertDebug(SSKEnvironment.shared.identityManager);

    return SSKEnvironment.shared.identityManager;
}

- (TSNetworkManager *)networkManager
{
    OWSAssertDebug(SSKEnvironment.shared.networkManager);

    return SSKEnvironment.shared.networkManager;
}

- (OWSOutgoingReceiptManager *)outgoingReceiptManager
{
    OWSAssertDebug(SSKEnvironment.shared.outgoingReceiptManager);

    return SSKEnvironment.shared.outgoingReceiptManager;
}

- (id<OWSSyncManagerProtocol>)syncManager
{
    OWSAssertDebug(SSKEnvironment.shared.syncManager);

    return SSKEnvironment.shared.syncManager;
}

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

- (id<ProfileManagerProtocol>)profileManager
{
    return SSKEnvironment.shared.profileManager;
}

- (id<OWSTypingIndicators>)typingIndicators
{
    return SSKEnvironment.shared.typingIndicators;
}

- (OWSAttachmentDownloads *)attachmentDownloads
{
    return SSKEnvironment.shared.attachmentDownloads;
}

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

- (SSKSessionStore *)sessionStore
{
    return SSKEnvironment.shared.sessionStore;
}

#pragma mark -

- (void)startObserving
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(yapDatabaseModified:)
                                                 name:YapDatabaseModifiedNotification
                                               object:OWSPrimaryStorage.sharedManager.dbNotificationObject];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(yapDatabaseModified:)
                                                 name:YapDatabaseModifiedExternallyNotification
                                               object:nil];
}

- (void)yapDatabaseModified:(NSNotification *)notification
{
    if (AppReadiness.isAppReady) {
        [OWSMessageUtils.sharedManager updateApplicationBadgeCount];
    } else {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [AppReadiness runNowOrWhenAppDidBecomeReady:^{
                [OWSMessageUtils.sharedManager updateApplicationBadgeCount];
            }];
        });
    }
}

#pragma mark - Blocking

- (BOOL)isEnvelopeSenderBlocked:(SSKProtoEnvelope *)envelope
{
    OWSAssertDebug(envelope);

    return [self.blockingManager isRecipientIdBlocked:envelope.source];
}

- (BOOL)isDataMessageBlocked:(SSKProtoDataMessage *)dataMessage envelope:(SSKProtoEnvelope *)envelope
{
    OWSAssertDebug(dataMessage);
    OWSAssertDebug(envelope);

    if (dataMessage.group) {
        return [self.blockingManager isGroupIdBlocked:dataMessage.group.id];
    } else {
        BOOL senderBlocked = [self isEnvelopeSenderBlocked:envelope];

        // If the envelopeSender was blocked, we never should have gotten as far as decrypting the dataMessage.
        OWSAssertDebug(!senderBlocked);

        return senderBlocked;
    }
}

#pragma mark - message handling

- (void)throws_processEnvelope:(SSKProtoEnvelope *)envelope
                 plaintextData:(NSData *_Nullable)plaintextData
               wasReceivedByUD:(BOOL)wasReceivedByUD
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }
    if (!self.tsAccountManager.isRegistered) {
        OWSFailDebug(@"Not registered.");
        return;
    }
    if (!CurrentAppContext().isMainApp) {
        OWSFail(@"Not main app.");
        return;
    }

    OWSLogInfo(@"handling decrypted envelope: %@", [self descriptionForEnvelope:envelope]);

    if (!envelope.hasSource || envelope.source.length < 1 || !envelope.source.isValidE164) {
        OWSFailDebug(@"incoming envelope has invalid source");
        return;
    }
    if (!envelope.hasSourceDevice || envelope.sourceDevice < 1) {
        OWSFailDebug(@"incoming envelope has invalid source device");
        return;
    }
    if (!envelope.hasType) {
        OWSFailDebug(@"incoming envelope is missing type.");
        return;
    }

    if ([self isEnvelopeSenderBlocked:envelope]) {
        OWSLogInfo(@"incoming envelope sender is blocked.");
        return;
    }

    [self checkForUnknownLinkedDevice:envelope transaction:transaction];

    switch (envelope.unwrappedType) {
        case SSKProtoEnvelopeTypeCiphertext:
        case SSKProtoEnvelopeTypePrekeyBundle:
        case SSKProtoEnvelopeTypeUnidentifiedSender:
            if (!plaintextData) {
                OWSFailDebug(@"missing decrypted data for envelope: %@", [self descriptionForEnvelope:envelope]);
                return;
            }
            [self throws_handleEnvelope:envelope
                          plaintextData:plaintextData
                        wasReceivedByUD:wasReceivedByUD
                            transaction:transaction];
            break;
        case SSKProtoEnvelopeTypeReceipt:
            OWSAssertDebug(!plaintextData);
            [self handleDeliveryReceipt:envelope transaction:transaction];
            break;
            // Other messages are just dismissed for now.
        case SSKProtoEnvelopeTypeKeyExchange:
            OWSLogWarn(@"Received Key Exchange Message, not supported");
            break;
        case SSKProtoEnvelopeTypeUnknown:
            OWSLogWarn(@"Received an unknown message type");
            break;
        default:
            OWSLogWarn(@"Received unhandled envelope type: %d", (int)envelope.unwrappedType);
            break;
    }
}

- (void)handleDeliveryReceipt:(SSKProtoEnvelope *)envelope transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    // Old-style delivery notices don't include a "delivery timestamp".
    [self processDeliveryReceiptsFromRecipientId:envelope.source
                                  sentTimestamps:@[
                                      @(envelope.timestamp),
                                  ]
                               deliveryTimestamp:nil
                                     transaction:transaction];
}

// deliveryTimestamp is an optional parameter, since legacy
// delivery receipts don't have a "delivery timestamp".  Those
// messages repurpose the "timestamp" field to indicate when the
// corresponding message was originally sent.
- (void)processDeliveryReceiptsFromRecipientId:(NSString *)recipientId
                                sentTimestamps:(NSArray<NSNumber *> *)sentTimestamps
                             deliveryTimestamp:(NSNumber *_Nullable)deliveryTimestamp
                                   transaction:(SDSAnyWriteTransaction *)transaction
{
    if (recipientId.length < 1) {
        OWSFailDebug(@"Empty recipientId.");
        return;
    }
    if (sentTimestamps.count < 1) {
        OWSFailDebug(@"Missing sentTimestamps.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    for (NSNumber *nsTimestamp in sentTimestamps) {
        uint64_t timestamp = [nsTimestamp unsignedLongLongValue];

        NSArray<TSOutgoingMessage *> *messages = (NSArray<TSOutgoingMessage *> *)[TSInteraction
            interactionsWithTimestamp:timestamp
                              ofClass:[TSOutgoingMessage class]
                      withTransaction:transaction.transitional_yapWriteTransaction];
        if (messages.count < 1) {
            // The service sends delivery receipts for "unpersisted" messages
            // like group updates, so these errors are expected to a certain extent.
            //
            // TODO: persist "early" delivery receipts.
            OWSLogInfo(@"Missing message for delivery receipt: %llu", timestamp);
        } else {
            if (messages.count > 1) {
                OWSLogInfo(@"More than one message (%lu) for delivery receipt: %llu",
                    (unsigned long)messages.count,
                    timestamp);
            }
            for (TSOutgoingMessage *outgoingMessage in messages) {
                [outgoingMessage updateWithDeliveredRecipient:recipientId
                                            deliveryTimestamp:deliveryTimestamp
                                                  transaction:transaction.transitional_yapWriteTransaction];
            }
        }
    }
}

- (void)throws_handleEnvelope:(SSKProtoEnvelope *)envelope
                plaintextData:(NSData *)plaintextData
              wasReceivedByUD:(BOOL)wasReceivedByUD
                  transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!plaintextData) {
        OWSFailDebug(@"Missing plaintextData.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }
    if (envelope.timestamp < 1) {
        OWSFailDebug(@"Invalid timestamp.");
        return;
    }
    if (envelope.source.length < 1) {
        OWSFailDebug(@"Missing source.");
        return;
    }
    if (envelope.sourceDevice < 1) {
        OWSFailDebug(@"Invaid source device.");
        return;
    }

    BOOL duplicateEnvelope = [InteractionFinder existsIncomingMessageWithTimestamp:envelope.timestamp
                                                                          sourceId:envelope.source
                                                                    sourceDeviceId:envelope.sourceDevice
                                                                       transaction:transaction];

    if (duplicateEnvelope) {
        OWSLogInfo(@"Ignoring previously received envelope from %@ with timestamp: %llu",
            envelopeAddress(envelope),
            envelope.timestamp);
        return;
    }

    if (envelope.content != nil) {
        NSError *error;
        SSKProtoContent *_Nullable contentProto = [SSKProtoContent parseData:plaintextData error:&error];
        if (error || !contentProto) {
            OWSFailDebug(@"could not parse proto: %@", error);
            return;
        }
        OWSLogInfo(@"handling content: <Content: %@>", [self descriptionForContent:contentProto]);

        if (contentProto.syncMessage) {
            [self throws_handleIncomingEnvelope:envelope
                                withSyncMessage:contentProto.syncMessage
                                    transaction:transaction];

            [[OWSDeviceManager sharedManager] setHasReceivedSyncMessage];
        } else if (contentProto.dataMessage) {
            [self handleIncomingEnvelope:envelope
                         withDataMessage:contentProto.dataMessage
                         wasReceivedByUD:wasReceivedByUD
                             transaction:transaction];
        } else if (contentProto.callMessage) {
            [self handleIncomingEnvelope:envelope withCallMessage:contentProto.callMessage];
        } else if (contentProto.typingMessage) {
            [self handleIncomingEnvelope:envelope withTypingMessage:contentProto.typingMessage transaction:transaction];
        } else if (contentProto.nullMessage) {
            OWSLogInfo(@"Received null message.");
        } else if (contentProto.receiptMessage) {
            [self handleIncomingEnvelope:envelope
                      withReceiptMessage:contentProto.receiptMessage
                             transaction:transaction];
        } else {
            OWSLogWarn(@"Ignoring envelope. Content with no known payload");
        }
    } else if (envelope.legacyMessage != nil) { // DEPRECATED - Remove after all clients have been upgraded.
        NSError *error;
        SSKProtoDataMessage *_Nullable dataMessageProto = [SSKProtoDataMessage parseData:plaintextData error:&error];
        if (error || !dataMessageProto) {
            OWSFailDebug(@"could not parse proto: %@", error);
            return;
        }
        OWSLogInfo(@"handling message: <DataMessage: %@ />", [self descriptionForDataMessage:dataMessageProto]);

        [self handleIncomingEnvelope:envelope
                     withDataMessage:dataMessageProto
                     wasReceivedByUD:wasReceivedByUD
                         transaction:transaction];
    } else {
        OWSProdInfoWEnvelope([OWSAnalyticsEvents messageManagerErrorEnvelopeNoActionablePayload], envelope);
    }
}

- (void)handleIncomingEnvelope:(SSKProtoEnvelope *)envelope
               withDataMessage:(SSKProtoDataMessage *)dataMessage
               wasReceivedByUD:(BOOL)wasReceivedByUD
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    if ([self isDataMessageBlocked:dataMessage envelope:envelope]) {
        NSString *logMessage = [NSString stringWithFormat:@"Ignoring blocked message from sender: %@", envelope.source];
        if (dataMessage.group) {
            logMessage = [logMessage stringByAppendingFormat:@" in group: %@", dataMessage.group.id];
        }
        OWSLogError(@"%@", logMessage);
        return;
    }

    if (dataMessage.hasTimestamp) {
        if (dataMessage.timestamp <= 0) {
            OWSFailDebug(@"Ignoring message with invalid data message timestamp: %@", envelope.source);
            // TODO: Add analytics.
            return;
        }
        // This prevents replay attacks by the service.
        if (dataMessage.timestamp != envelope.timestamp) {
            OWSFailDebug(@"Ignoring message with non-matching data message timestamp: %@", envelope.source);
            // TODO: Add analytics.
            return;
        }
    }

    if ([dataMessage hasProfileKey]) {
        NSData *profileKey = [dataMessage profileKey];
        NSString *recipientId = envelope.source;
        if (profileKey.length == kAES256_KeyByteLength) {
            [self.profileManager setProfileKeyData:profileKey forRecipientId:recipientId];
        } else {
            OWSFailDebug(
                @"Unexpected profile key length:%lu on message from:%@", (unsigned long)profileKey.length, recipientId);
        }
    }

    if (dataMessage.group) {
        TSGroupThread *_Nullable groupThread =
            [TSGroupThread threadWithGroupId:dataMessage.group.id anyTransaction:transaction];

        if (!dataMessage.group.hasType) {
            OWSFailDebug(@"Group message is missing type.");
            return;
        }
        if (groupThread) {
            if (dataMessage.group.unwrappedType != SSKProtoGroupContextTypeUpdate) {
                if (!groupThread.isLocalUserInGroup) {
                    OWSLogInfo(@"Ignoring messages for left group.");
                    return;
                }
            }
        } else {
            // Unknown group.
            if (dataMessage.group.unwrappedType == SSKProtoGroupContextTypeUpdate) {
                // Accept group updates for unknown groups.
            } else if (dataMessage.group.unwrappedType == SSKProtoGroupContextTypeDeliver) {
                [self sendGroupInfoRequest:dataMessage.group.id envelope:envelope transaction:transaction];
                return;
            } else {
                OWSLogInfo(@"Ignoring group message for unknown group from: %@", envelope.source);
                return;
            }
        }
    }

    if ((dataMessage.flags & SSKProtoDataMessageFlagsEndSession) != 0) {
        [self handleEndSessionMessageWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    } else if ((dataMessage.flags & SSKProtoDataMessageFlagsExpirationTimerUpdate) != 0) {
        [self handleExpirationTimerUpdateMessageWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    } else if ((dataMessage.flags & SSKProtoDataMessageFlagsProfileKeyUpdate) != 0) {
        [self handleProfileKeyMessageWithEnvelope:envelope dataMessage:dataMessage];
    } else if (dataMessage.attachments.count > 0) {
        [self handleReceivedMediaWithEnvelope:envelope
                                  dataMessage:dataMessage
                              wasReceivedByUD:wasReceivedByUD
                                  transaction:transaction];
    } else {
        [self handleReceivedTextMessageWithEnvelope:envelope
                                        dataMessage:dataMessage
                                    wasReceivedByUD:wasReceivedByUD
                                        transaction:transaction];

        if ([self isDataMessageGroupAvatarUpdate:dataMessage]) {
            OWSLogVerbose(@"Data message had group avatar attachment");
            [self handleReceivedGroupAvatarUpdateWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
        }
    }

    // Send delivery receipts for "valid data" messages received via UD.
    if (wasReceivedByUD) {
        [self.outgoingReceiptManager enqueueDeliveryReceiptForEnvelope:envelope];
    }
}

- (void)sendGroupInfoRequest:(NSData *)groupId
                    envelope:(SSKProtoEnvelope *)envelope
                 transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }
    if (groupId.length < 1) {
        OWSFailDebug(@"Invalid groupId.");
        return;
    }

    // FIXME: https://github.com/signalapp/Signal-iOS/issues/1340
    OWSLogInfo(@"Sending group info request: %@", envelopeAddress(envelope));

    NSString *recipientId = envelope.source;

    TSThread *thread = [TSContactThread getOrCreateThreadWithContactId:recipientId anyTransaction:transaction];

    OWSSyncGroupsRequestMessage *syncGroupsRequestMessage =
        [[OWSSyncGroupsRequestMessage alloc] initWithThread:thread groupId:groupId];

    [self.messageSenderJobQueue addMessage:syncGroupsRequestMessage transaction:transaction];
}

- (void)handleIncomingEnvelope:(SSKProtoEnvelope *)envelope
            withReceiptMessage:(SSKProtoReceiptMessage *)receiptMessage
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!receiptMessage) {
        OWSFailDebug(@"Missing receiptMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }
    if (!receiptMessage.hasType) {
        OWSFail(@"Missing type.");
        return;
    }

    NSArray<NSNumber *> *sentTimestamps = receiptMessage.timestamp;

    switch (receiptMessage.unwrappedType) {
        case SSKProtoReceiptMessageTypeDelivery:
            OWSLogVerbose(@"Processing receipt message with delivery receipts.");
            [self processDeliveryReceiptsFromRecipientId:envelope.source
                                          sentTimestamps:sentTimestamps
                                       deliveryTimestamp:@(envelope.timestamp)
                                             transaction:transaction];
            return;
        case SSKProtoReceiptMessageTypeRead:
            OWSLogVerbose(@"Processing receipt message with read receipts.");
            [OWSReadReceiptManager.sharedManager processReadReceiptsFromRecipientId:envelope.source
                                                                     sentTimestamps:sentTimestamps
                                                                      readTimestamp:envelope.timestamp];
            break;
        default:
            OWSLogInfo(@"Ignoring receipt message of unknown type: %d.", (int)receiptMessage.unwrappedType);
            return;
    }
}

- (void)handleIncomingEnvelope:(SSKProtoEnvelope *)envelope
               withCallMessage:(SSKProtoCallMessage *)callMessage
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!callMessage) {
        OWSFailDebug(@"Missing callMessage.");
        return;
    }

    if ([self isEnvelopeSenderBlocked:envelope]) {
        OWSFailDebug(@"envelope sender is blocked. Shouldn't have gotten this far.");
        return;
    }

    if ([callMessage hasProfileKey]) {
        NSData *profileKey = [callMessage profileKey];
        NSString *recipientId = envelope.source;
        [self.profileManager setProfileKeyData:profileKey forRecipientId:recipientId];
    }

    // By dispatching async, we introduce the possibility that these messages might be lost
    // if the app exits before this block is executed.  This is fine, since the call by
    // definition will end if the app exits.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (callMessage.offer) {
            [self.callMessageHandler receivedOffer:callMessage.offer fromCallerId:envelope.source];
        } else if (callMessage.answer) {
            [self.callMessageHandler receivedAnswer:callMessage.answer fromCallerId:envelope.source];
        } else if (callMessage.iceUpdate.count > 0) {
            for (SSKProtoCallMessageIceUpdate *iceUpdate in callMessage.iceUpdate) {
                [self.callMessageHandler receivedIceUpdate:iceUpdate fromCallerId:envelope.source];
            }
        } else if (callMessage.hangup) {
            OWSLogVerbose(@"Received CallMessage with Hangup.");
            [self.callMessageHandler receivedHangup:callMessage.hangup fromCallerId:envelope.source];
        } else if (callMessage.busy) {
            [self.callMessageHandler receivedBusy:callMessage.busy fromCallerId:envelope.source];
        } else {
            OWSProdInfoWEnvelope([OWSAnalyticsEvents messageManagerErrorCallMessageNoActionablePayload], envelope);
        }
    });
}

- (void)handleIncomingEnvelope:(SSKProtoEnvelope *)envelope
             withTypingMessage:(SSKProtoTypingMessage *)typingMessage
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!typingMessage) {
        OWSFailDebug(@"Missing typingMessage.");
        return;
    }
    if (typingMessage.timestamp != envelope.timestamp) {
        OWSFailDebug(@"typingMessage has invalid timestamp.");
        return;
    }
    NSString *localNumber = self.tsAccountManager.localNumber;
    if ([localNumber isEqualToString:envelope.source]) {
        OWSLogVerbose(@"Ignoring typing indicators from self or linked device.");
        return;
    } else if ([self.blockingManager isRecipientIdBlocked:envelope.source]
        || (typingMessage.hasGroupID && [self.blockingManager isGroupIdBlocked:typingMessage.groupID])) {
        NSString *logMessage = [NSString stringWithFormat:@"Ignoring blocked message from sender: %@", envelope.source];
        if (typingMessage.hasGroupID) {
            logMessage = [logMessage stringByAppendingFormat:@" in group: %@", typingMessage.groupID];
        }
        OWSLogError(@"%@", logMessage);
        return;
    }

    TSThread *_Nullable thread;
    if (typingMessage.hasGroupID) {
        TSGroupThread *groupThread = [TSGroupThread threadWithGroupId:typingMessage.groupID anyTransaction:transaction];

        if (!groupThread.isLocalUserInGroup) {
            OWSLogInfo(@"Ignoring messages for left group.");
            return;
        }

        thread = groupThread;
    } else {
        thread = [TSContactThread getThreadWithContactId:envelope.source anyTransaction:transaction];
    }

    if (!thread) {
        // This isn't neccesarily an error.  We might not yet know about the thread,
        // in which case we don't need to display the typing indicators.
        OWSLogWarn(@"Could not locate thread for typingMessage.");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!typingMessage.hasAction) {
            OWSFailDebug(@"Type message is missing action.");
            return;
        }
        switch (typingMessage.unwrappedAction) {
            case SSKProtoTypingMessageActionStarted:
                [self.typingIndicators didReceiveTypingStartedMessageInThread:thread
                                                                  recipientId:envelope.source
                                                                     deviceId:envelope.sourceDevice];
                break;
            case SSKProtoTypingMessageActionStopped:
                [self.typingIndicators didReceiveTypingStoppedMessageInThread:thread
                                                                  recipientId:envelope.source
                                                                     deviceId:envelope.sourceDevice];
                break;
            default:
                OWSFailDebug(@"Typing message has unexpected action.");
                break;
        }
    });
}

- (void)handleReceivedGroupAvatarUpdateWithEnvelope:(SSKProtoEnvelope *)envelope
                                        dataMessage:(SSKProtoDataMessage *)dataMessage
                                        transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    TSGroupThread *_Nullable groupThread =
        [TSGroupThread threadWithGroupId:dataMessage.group.id anyTransaction:transaction];
    if (!groupThread) {
        OWSFailDebug(@"Missing group for group avatar update");
        return;
    }

    TSAttachmentPointer *_Nullable avatarPointer =
        [TSAttachmentPointer attachmentPointerFromProto:dataMessage.group.avatar albumMessage:nil];

    if (!avatarPointer) {
        OWSLogWarn(@"received unsupported group avatar envelope");
        return;
    }

    [avatarPointer anyInsertWithTransaction:transaction];

    [self.attachmentDownloads downloadAttachmentPointer:avatarPointer
        message:nil
        success:^(NSArray<TSAttachmentStream *> *attachmentStreams) {
            OWSAssertDebug(attachmentStreams.count == 1);
            TSAttachmentStream *attachmentStream = attachmentStreams.firstObject;

            [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
                [groupThread updateAvatarWithAttachmentStream:attachmentStream transaction:transaction];

                // Eagerly clean up the attachment.
                [attachmentStream anyRemoveWithTransaction:transaction];
            }];
        }
        failure:^(NSError *error) {
            OWSLogError(@"failed to fetch attachments for group avatar sent at: %llu. with error: %@",
                envelope.timestamp,
                error);

            [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
                // Eagerly clean up the attachment.
                TSAttachment *_Nullable attachment =
                    [TSAttachment anyFetchWithUniqueId:avatarPointer.uniqueId transaction:transaction];
                if (attachment == nil) {
                    OWSFailDebug(@"Could not load attachment.");
                    return;
                }
                [attachment anyRemoveWithTransaction:transaction];
            }];
        }];
}

- (void)handleReceivedMediaWithEnvelope:(SSKProtoEnvelope *)envelope
                            dataMessage:(SSKProtoDataMessage *)dataMessage
                        wasReceivedByUD:(BOOL)wasReceivedByUD
                            transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    TSThread *_Nullable thread = [self threadForEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    if (!thread) {
        OWSFailDebug(@"ignoring media message for unknown group.");
        return;
    }

    TSIncomingMessage *_Nullable message = [self handleReceivedEnvelope:envelope
                                                        withDataMessage:dataMessage
                                                        wasReceivedByUD:wasReceivedByUD
                                                            transaction:transaction];

    if (!message) {
        return;
    }

    OWSAssertDebug([TSMessage anyFetchWithUniqueId:message.uniqueId transaction:transaction] != nil);

    OWSLogDebug(@"incoming attachment message: %@", message.debugDescription);

    [self.attachmentDownloads downloadBodyAttachmentsForMessage:message
        transaction:transaction
        success:^(NSArray<TSAttachmentStream *> *attachmentStreams) {
            OWSLogDebug(@"successfully fetched attachments: %lu for message: %@",
                (unsigned long)attachmentStreams.count,
                message);
        }
        failure:^(NSError *error) {
            OWSLogError(@"failed to fetch attachments for message: %@ with error: %@", message, error);
        }];
}

- (void)throws_handleIncomingEnvelope:(SSKProtoEnvelope *)envelope
                      withSyncMessage:(SSKProtoSyncMessage *)syncMessage
                          transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!syncMessage) {
        OWSFailDebug(@"Missing syncMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    NSString *localNumber = self.tsAccountManager.localNumber;
    if (![localNumber isEqualToString:envelope.source]) {
        // Sync messages should only come from linked devices.
        OWSProdErrorWEnvelope([OWSAnalyticsEvents messageManagerErrorSyncMessageFromUnknownSource], envelope);
        return;
    }

    if (syncMessage.sent) {
        OWSIncomingSentMessageTranscript *transcript =
            [[OWSIncomingSentMessageTranscript alloc] initWithProto:syncMessage.sent
                                                        transaction:transaction.transitional_yapWriteTransaction];

        SSKProtoDataMessage *_Nullable dataMessage = syncMessage.sent.message;
        if (!dataMessage) {
            OWSFailDebug(@"Missing dataMessage.");
            return;
        }
        NSString *destination = syncMessage.sent.destination;
        if (dataMessage && destination.length > 0 && dataMessage.hasProfileKey) {
            // If we observe a linked device sending our profile key to another
            // user, we can infer that that user belongs in our profile whitelist.
            if (dataMessage.group) {
                [self.profileManager addGroupIdToProfileWhitelist:dataMessage.group.id];
            } else {
                [self.profileManager addUserToProfileWhitelist:destination];
            }
        }

        if ([self isDataMessageGroupAvatarUpdate:syncMessage.sent.message] && !syncMessage.sent.isRecipientUpdate) {
            [OWSRecordTranscriptJob
                processIncomingSentMessageTranscript:transcript
                                   attachmentHandler:^(NSArray<TSAttachmentStream *> *attachmentStreams) {
                                       OWSAssertDebug(attachmentStreams.count == 1);
                                       TSAttachmentStream *attachmentStream = attachmentStreams.firstObject;
                                       [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
                                           TSGroupThread *_Nullable groupThread =
                                               [TSGroupThread threadWithGroupId:dataMessage.group.id
                                                                 anyTransaction:transaction];
                                           if (!groupThread) {
                                               OWSFailDebug(@"ignoring sync group avatar update for unknown group.");
                                               return;
                                           }

                                           [groupThread updateAvatarWithAttachmentStream:attachmentStream
                                                                             transaction:transaction];
                                       }];
                                   }
                                         transaction:transaction.transitional_yapWriteTransaction];
        } else {
            [OWSRecordTranscriptJob
                processIncomingSentMessageTranscript:transcript
                                   attachmentHandler:^(NSArray<TSAttachmentStream *> *attachmentStreams) {
                                       OWSLogDebug(@"successfully fetched transcript attachments: %lu",
                                           (unsigned long)attachmentStreams.count);
                                   }
                                         transaction:transaction.transitional_yapWriteTransaction];
        }
    } else if (syncMessage.request) {
        if (!syncMessage.request.hasType) {
            OWSFailDebug(@"Ignoring sync request without type.");
            return;
        }
        if (syncMessage.request.unwrappedType == SSKProtoSyncMessageRequestTypeContacts) {
            // We respond asynchronously because populating the sync message will
            // create transactions and it's not practical (due to locking in the OWSIdentityManager)
            // to plumb our transaction through.
            //
            // In rare cases this means we won't respond to the sync request, but that's
            // acceptable.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[self.syncManager syncAllContacts] retainUntilComplete];
            });
        } else if (syncMessage.request.unwrappedType == SSKProtoSyncMessageRequestTypeGroups) {
            OWSSyncGroupsMessage *syncGroupsMessage = [[OWSSyncGroupsMessage alloc] init];
            NSData *_Nullable syncData = [syncGroupsMessage
                buildPlainTextAttachmentDataWithTransaction:transaction.transitional_yapReadTransaction];
            if (!syncData) {
                OWSFailDebug(@"Failed to serialize groups sync message.");
                return;
            }
            DataSource *dataSource = [DataSourceValue dataSourceWithSyncMessageData:syncData];
            [self.messageSenderJobQueue addMediaMessage:syncGroupsMessage
                                             dataSource:dataSource
                                            contentType:OWSMimeTypeApplicationOctetStream
                                         sourceFilename:nil
                                                caption:nil
                                         albumMessageId:nil
                                  isTemporaryAttachment:YES];
        } else if (syncMessage.request.unwrappedType == SSKProtoSyncMessageRequestTypeBlocked) {
            OWSLogInfo(@"Received request for block list");
            [self.blockingManager syncBlockList];
        } else if (syncMessage.request.unwrappedType == SSKProtoSyncMessageRequestTypeConfiguration) {
            [SSKEnvironment.shared.syncManager sendConfigurationSyncMessage];

            // We send _two_ responses to the "configuration request".
            [StickerManager syncAllInstalledPacksWithTransaction:transaction];
        } else {
            OWSLogWarn(@"ignoring unsupported sync request message");
        }
    } else if (syncMessage.blocked) {
        NSArray<NSString *> *blockedPhoneNumbers = [syncMessage.blocked.numbers copy];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.blockingManager setBlockedPhoneNumbers:blockedPhoneNumbers sendSyncMessage:NO];
        });
    } else if (syncMessage.read.count > 0) {
        OWSLogInfo(@"Received %lu read receipt(s)", (unsigned long)syncMessage.read.count);
        [OWSReadReceiptManager.sharedManager
            processReadReceiptsFromLinkedDevice:syncMessage.read
                                  readTimestamp:envelope.timestamp
                                    transaction:transaction.transitional_yapWriteTransaction];
    } else if (syncMessage.verified) {
        OWSLogInfo(@"Received verification state for %@", syncMessage.verified.destination);
        [self.identityManager throws_processIncomingSyncMessage:syncMessage.verified transaction:transaction];
    } else if (syncMessage.stickerPackOperation.count > 0) {
        OWSLogInfo(@"Received sticker pack operation(s): %d", (int)syncMessage.stickerPackOperation.count);
        for (SSKProtoSyncMessageStickerPackOperation *packOperationProto in syncMessage.stickerPackOperation) {
            [StickerManager processIncomingStickerPackOperation:packOperationProto transaction:transaction];
        }
    } else if (syncMessage.messageTimerRead != nil) {
        OWSLogInfo(@"Received per-message expiration sync message");
        [PerMessageExpiration processIncomingSyncMessage:syncMessage.messageTimerRead
                                                envelope:envelope
                                             transaction:transaction];
    } else {
        OWSLogWarn(@"Ignoring unsupported sync message.");
    }
}

- (void)handleEndSessionMessageWithEnvelope:(SSKProtoEnvelope *)envelope
                                dataMessage:(SSKProtoDataMessage *)dataMessage
                                transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    TSContactThread *thread =
        [TSContactThread getOrCreateThreadWithContactId:envelope.source anyTransaction:transaction];

    // MJK TODO - safe to remove senderTimestamp
    [[[TSInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                     inThread:thread
                                  messageType:TSInfoMessageTypeSessionDidEnd] anyInsertWithTransaction:transaction];

    [self.sessionStore deleteAllSessionsForContact:envelope.source transaction:transaction];
}

- (void)handleExpirationTimerUpdateMessageWithEnvelope:(SSKProtoEnvelope *)envelope
                                           dataMessage:(SSKProtoDataMessage *)dataMessage
                                           transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    TSThread *_Nullable thread = [self threadForEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    if (!thread) {
        OWSFailDebug(@"ignoring expiring messages update for unknown group.");
        return;
    }

    OWSDisappearingMessagesConfiguration *disappearingMessagesConfiguration;
    if (dataMessage.hasExpireTimer && dataMessage.expireTimer > 0) {
        OWSLogInfo(
            @"Expiring messages duration turned to %u for thread %@", (unsigned int)dataMessage.expireTimer, thread);
        disappearingMessagesConfiguration =
            [[OWSDisappearingMessagesConfiguration alloc] initWithThreadId:thread.uniqueId
                                                                   enabled:YES
                                                           durationSeconds:dataMessage.expireTimer];
    } else {
        OWSLogInfo(@"Expiring messages have been turned off for thread %@", thread);
        disappearingMessagesConfiguration = [[OWSDisappearingMessagesConfiguration alloc]
            initWithThreadId:thread.uniqueId
                     enabled:NO
             durationSeconds:OWSDisappearingMessagesConfigurationDefaultExpirationDuration];
    }
    OWSAssertDebug(disappearingMessagesConfiguration);
    [disappearingMessagesConfiguration anyInsertWithTransaction:transaction];
    NSString *name = [self.contactsManager displayNameForPhoneIdentifier:envelope.source
                                                             transaction:transaction.transitional_yapWriteTransaction];

    // MJK TODO - safe to remove senderTimestamp
    OWSDisappearingConfigurationUpdateInfoMessage *message =
        [[OWSDisappearingConfigurationUpdateInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                                          thread:thread
                                                                   configuration:disappearingMessagesConfiguration
                                                             createdByRemoteName:name
                                                          createdInExistingGroup:NO];
    [message anyInsertWithTransaction:transaction];
}

- (void)handleProfileKeyMessageWithEnvelope:(SSKProtoEnvelope *)envelope
                                dataMessage:(SSKProtoDataMessage *)dataMessage
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }

    NSString *recipientId = envelope.source;
    if (!dataMessage.hasProfileKey) {
        OWSFailDebug(@"received profile key message without profile key from: %@", envelopeAddress(envelope));
        return;
    }
    NSData *profileKey = dataMessage.profileKey;
    if (profileKey.length != kAES256_KeyByteLength) {
        OWSFailDebug(@"received profile key of unexpected length: %lu, from: %@",
            (unsigned long)profileKey.length,
            envelopeAddress(envelope));
        return;
    }

    id<ProfileManagerProtocol> profileManager = SSKEnvironment.shared.profileManager;
    [profileManager setProfileKeyData:profileKey forRecipientId:recipientId];
}

- (void)handleReceivedTextMessageWithEnvelope:(SSKProtoEnvelope *)envelope
                                  dataMessage:(SSKProtoDataMessage *)dataMessage
                              wasReceivedByUD:(BOOL)wasReceivedByUD
                                  transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }

    [self handleReceivedEnvelope:envelope
                 withDataMessage:dataMessage
                 wasReceivedByUD:wasReceivedByUD
                     transaction:transaction];
}

- (void)handleGroupInfoRequest:(SSKProtoEnvelope *)envelope
                   dataMessage:(SSKProtoDataMessage *)dataMessage
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return;
    }
    if (!dataMessage.group.hasType) {
        OWSFailDebug(@"Missing group message type.");
        return;
    }
    if (dataMessage.group.unwrappedType != SSKProtoGroupContextTypeRequestInfo) {
        OWSFailDebug(@"Unexpected group message type.");
        return;
    }

    NSData *groupId = dataMessage.group ? dataMessage.group.id : nil;
    if (!groupId) {
        OWSFailDebug(@"Group info request is missing group id.");
        return;
    }

    OWSLogInfo(@"Received 'Request Group Info' message for group: %@ from: %@", groupId, envelope.source);

    TSGroupThread *_Nullable gThread =
        [TSGroupThread threadWithGroupId:dataMessage.group.id anyTransaction:transaction];
    if (!gThread) {
        OWSLogWarn(@"Unknown group: %@", groupId);
        return;
    }

    // Ensure sender is in the group.
    if (![gThread.groupModel.groupMemberIds containsObject:envelope.source]) {
        OWSLogWarn(@"Ignoring 'Request Group Info' message for non-member of group. %@ not in %@",
            envelope.source,
            gThread.groupModel.groupMemberIds);
        return;
    }

    // Ensure we are in the group.
    if (!gThread.isLocalUserInGroup) {
        OWSLogWarn(@"Ignoring 'Request Group Info' message for group we no longer belong to.");
        return;
    }

    NSString *updateGroupInfo =
        [gThread.groupModel getInfoStringAboutUpdateTo:gThread.groupModel contactsManager:self.contactsManager];

    uint32_t expiresInSeconds =
        [gThread disappearingMessagesDurationWithTransaction:transaction.transitional_yapWriteTransaction];
    TSOutgoingMessage *message = [TSOutgoingMessage outgoingMessageInThread:gThread
                                                           groupMetaMessage:TSGroupMetaMessageUpdate
                                                           expiresInSeconds:expiresInSeconds];

    [message updateWithCustomMessage:updateGroupInfo transaction:transaction.transitional_yapWriteTransaction];
    // Only send this group update to the requester.
    [message updateWithSendingToSingleGroupRecipient:envelope.source
                                         transaction:transaction.transitional_yapWriteTransaction];

    if (gThread.groupModel.groupImage) {
        NSData *_Nullable data = UIImagePNGRepresentation(gThread.groupModel.groupImage);
        OWSAssertDebug(data);
        if (data) {
            DataSource *_Nullable dataSource = [DataSourceValue dataSourceWithData:data fileExtension:@"png"];
            [self.messageSenderJobQueue addMediaMessage:message
                                             dataSource:dataSource
                                            contentType:OWSMimeTypeImagePng
                                         sourceFilename:nil
                                                caption:nil
                                         albumMessageId:nil
                                  isTemporaryAttachment:YES];
        }
    } else {
        [self.messageSenderJobQueue addMessage:message transaction:transaction];
    }
}

- (TSIncomingMessage *_Nullable)handleReceivedEnvelope:(SSKProtoEnvelope *)envelope
                                       withDataMessage:(SSKProtoDataMessage *)dataMessage
                                       wasReceivedByUD:(BOOL)wasReceivedByUD
                                           transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return nil;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return nil;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return nil;
    }

    uint64_t timestamp = envelope.timestamp;
    NSData *groupId = dataMessage.group ? dataMessage.group.id : nil;

    if (groupId.length > 0) {
        if (!dataMessage.group.hasType) {
            OWSFailDebug(@"Missing group message type.");
            return nil;
        }

        if (dataMessage.group.unwrappedType == SSKProtoGroupContextTypeRequestInfo) {
            [self handleGroupInfoRequest:envelope dataMessage:dataMessage transaction:transaction];
            return nil;
        }

        NSMutableSet *newMemberIds = [NSMutableSet setWithArray:dataMessage.group.members];
        for (NSString *recipientId in newMemberIds) {
            if (!recipientId.isValidE164) {
                OWSLogVerbose(
                    @"incoming group update has invalid group member: %@", [self descriptionForEnvelope:envelope]);
                OWSFailDebug(@"incoming group update has invalid group member");
                return nil;
            }
        }

        // Group messages create the group if it doesn't already exist.
        //
        // We distinguish between the old group state (if any) and the new group state.
        TSGroupThread *_Nullable oldGroupThread = [TSGroupThread threadWithGroupId:groupId anyTransaction:transaction];
        if (oldGroupThread) {
            // Don't trust other clients; ensure all known group members remain in the
            // group unless it is a "quit" message in which case we should only remove
            // the quiting member below.
            [newMemberIds addObjectsFromArray:oldGroupThread.groupModel.groupMemberIds];
        }

        if (dataMessage.hasRequiredProtocolVersion
            && dataMessage.requiredProtocolVersion > SSKProtos.currentProtocolVersion) {
            NSString *senderId = envelope.source;
            [self insertUnknownProtocolVersionErrorInThread:oldGroupThread
                                            protocolVersion:dataMessage.requiredProtocolVersion
                                                   senderId:senderId
                                                transaction:transaction];
            return nil;
        }

        switch (dataMessage.group.unwrappedType) {
            case SSKProtoGroupContextTypeUpdate: {
                // Ensures that the thread exists but doesn't update it.
                TSGroupThread *newGroupThread =
                    [TSGroupThread getOrCreateThreadWithGroupId:groupId anyTransaction:transaction];

                TSGroupModel *newGroupModel = [[TSGroupModel alloc] initWithTitle:dataMessage.group.name
                                                                        memberIds:newMemberIds.allObjects
                                                                            image:oldGroupThread.groupModel.groupImage
                                                                          groupId:dataMessage.group.id];
                NSString *updateGroupInfo = [newGroupThread.groupModel getInfoStringAboutUpdateTo:newGroupModel
                                                                                  contactsManager:self.contactsManager];
                [newGroupThread anyUpdateWithTransaction:transaction
                                                   block:^(TSThread *thread) {
                                                       TSGroupThread *groupThread = (TSGroupThread *)thread;
                                                       groupThread.groupModel = newGroupModel;
                                                   }];

                if (transaction.transitional_yapWriteTransaction) {
                    [[OWSDisappearingMessagesJob sharedJob]
                        becomeConsistentWithDisappearingDuration:dataMessage.expireTimer
                                                          thread:newGroupThread
                                      createdByRemoteRecipientId:nil
                                          createdInExistingGroup:YES
                                                     transaction:transaction.transitional_yapWriteTransaction];
                }

                // MJK TODO - should be safe to remove senderTimestamp
                TSInfoMessage *infoMessage = [[TSInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                                             inThread:newGroupThread
                                                                          messageType:TSInfoMessageTypeGroupUpdate
                                                                        customMessage:updateGroupInfo];
                [infoMessage anyInsertWithTransaction:transaction];

                return nil;
            }
            case SSKProtoGroupContextTypeQuit: {
                if (!oldGroupThread) {
                    OWSLogWarn(@"ignoring quit group message from unknown group.");
                    return nil;
                }
                [newMemberIds removeObject:envelope.source];
                [oldGroupThread anyUpdateWithTransaction:transaction
                                                   block:^(TSThread *thread) {
                                                       TSGroupThread *groupThread = (TSGroupThread *)thread;
                                                       groupThread.groupModel.groupMemberIds =
                                                           [newMemberIds.allObjects mutableCopy];
                                                   }];

                NSString *nameString =
                    [self.contactsManager displayNameForPhoneIdentifier:envelope.source
                                                            transaction:transaction.transitional_yapWriteTransaction];
                NSString *updateGroupInfo =
                    [NSString stringWithFormat:NSLocalizedString(@"GROUP_MEMBER_LEFT", @""), nameString];
                // MJK TODO - should be safe to remove senderTimestamp
                [[[TSInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                 inThread:oldGroupThread
                                              messageType:TSInfoMessageTypeGroupUpdate
                                            customMessage:updateGroupInfo] anyInsertWithTransaction:transaction];
                return nil;
            }
            case SSKProtoGroupContextTypeDeliver: {
                if (!oldGroupThread) {
                    OWSFailDebug(@"ignoring deliver group message from unknown group.");
                    return nil;
                }

                NSString *messageDescription =
                    [NSString stringWithFormat:@"Incoming message from: %@ for group: %@ with timestamp: %llu",
                              envelopeAddress(envelope),
                              groupId,
                              timestamp];
                return [self createIncomingMessageInThread:oldGroupThread
                                        messageDescription:messageDescription
                                                  envelope:envelope
                                               dataMessage:dataMessage
                                           wasReceivedByUD:wasReceivedByUD
                                               transaction:transaction];
            }
            default: {
                OWSLogWarn(@"Ignoring unknown group message type: %d", (int)dataMessage.group.unwrappedType);
                return nil;
            }
        }
    } else {
        TSContactThread *thread =
            [TSContactThread getOrCreateThreadWithContactId:envelope.source anyTransaction:transaction];
        
        if (dataMessage.hasRequiredProtocolVersion
            && dataMessage.requiredProtocolVersion > SSKProtos.currentProtocolVersion) {
            NSString *senderId = envelope.source;
            [self insertUnknownProtocolVersionErrorInThread:thread
                                            protocolVersion:dataMessage.requiredProtocolVersion
                                                   senderId:senderId
                                                transaction:transaction];
            return nil;
        }

        NSString *messageDescription = [NSString stringWithFormat:@"Incoming 1:1 message from: %@ with timestamp: %llu",
                                                 envelopeAddress(envelope),
                                                 timestamp];
        return [self createIncomingMessageInThread:thread
                                messageDescription:messageDescription
                                          envelope:envelope
                                       dataMessage:dataMessage
                                   wasReceivedByUD:wasReceivedByUD
                                       transaction:transaction];
    }
}

- (void)insertUnknownProtocolVersionErrorInThread:(TSThread *)thread
                                  protocolVersion:(NSUInteger)protocolVersion
                                         senderId:(NSString *)senderId
                                      transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(thread);
    OWSAssertDebug(transaction);

    OWSFailDebug(@"Unknown protocol version: %lu", (unsigned long)protocolVersion);

    if (senderId.length < 1) {
        OWSFailDebug(@"Missing sender.");
        return;
    }

    // We convert protocolVersion to a numeric value here.
    TSInteraction *message =
        [[OWSUnknownProtocolVersionMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                             thread:thread
                                                           senderId:senderId
                                                    protocolVersion:protocolVersion];
    [message anyInsertWithTransaction:transaction];
}

- (nullable TSIncomingMessage *)createIncomingMessageInThread:(TSThread *)thread
                                           messageDescription:(NSString *)messageDescription
                                                     envelope:(SSKProtoEnvelope *)envelope
                                                  dataMessage:(SSKProtoDataMessage *)dataMessage
                                              wasReceivedByUD:(BOOL)wasReceivedByUD
                                                  transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return nil;
    }
    if (!thread) {
        OWSFailDebug(@"Missing thread.");
        return nil;
    }
    NSString *authorId = envelope.source;
    if (authorId.length < 1) {
        OWSFailDebug(@"Missing authorId.");
        return nil;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return nil;
    }

    OWSLogDebug(@"%@", messageDescription);

    uint64_t timestamp = envelope.timestamp;
    NSString *body = dataMessage.body;
    NSNumber *_Nullable serverTimestamp = (envelope.hasServerTimestamp ? @(envelope.serverTimestamp) : nil);

    TSQuotedMessage *_Nullable quotedMessage =
        [TSQuotedMessage quotedMessageForDataMessage:dataMessage thread:thread transaction:transaction];

    OWSContact *_Nullable contact;
    OWSLinkPreview *_Nullable linkPreview;
    if (transaction.transitional_yapWriteTransaction) {
        [[OWSDisappearingMessagesJob sharedJob]
            becomeConsistentWithDisappearingDuration:dataMessage.expireTimer
                                              thread:thread
                          createdByRemoteRecipientId:authorId
                              createdInExistingGroup:NO
                                         transaction:transaction.transitional_yapWriteTransaction];

        contact = [OWSContacts contactForDataMessage:dataMessage transaction:transaction];

        NSError *linkPreviewError;
        linkPreview = [OWSLinkPreview buildValidatedLinkPreviewWithDataMessage:dataMessage
                                                                          body:body
                                                                   transaction:transaction
                                                                         error:&linkPreviewError];
        if (linkPreviewError && ![OWSLinkPreview isNoPreviewError:linkPreviewError]) {
            OWSLogError(@"linkPreviewError: %@", linkPreviewError);
        }
    } else {
        OWSLogWarn(@"GRDB TODO: process non-basic messages.");
    }

    NSError *stickerError;
    MessageSticker *_Nullable messageSticker =
        [MessageSticker buildValidatedMessageStickerWithDataMessage:dataMessage
                                                        transaction:transaction
                                                              error:&stickerError];
    if (stickerError && ![MessageSticker isNoStickerError:stickerError]) {
        OWSFailDebug(@"stickerError: %@", stickerError);
    }

    // Legit usage of senderTimestamp when creating an incoming group message record
    TSIncomingMessage *incomingMessage =
        [[TSIncomingMessage alloc] initIncomingMessageWithTimestamp:timestamp
                                                           inThread:thread
                                                           authorId:authorId
                                                     sourceDeviceId:envelope.sourceDevice
                                                        messageBody:body
                                                      attachmentIds:@[]
                                                   expiresInSeconds:dataMessage.expireTimer
                                                      quotedMessage:quotedMessage
                                                       contactShare:contact
                                                        linkPreview:linkPreview
                                                     messageSticker:messageSticker
                                                    serverTimestamp:serverTimestamp
                                                    wasReceivedByUD:wasReceivedByUD
                                perMessageExpirationDurationSeconds:dataMessage.messageTimer];
    if (!incomingMessage) {
        OWSFailDebug(@"Missing incomingMessage.");
        return nil;
    }

    NSArray<TSAttachmentPointer *> *attachmentPointers =
        [TSAttachmentPointer attachmentPointersFromProtos:dataMessage.attachments albumMessage:incomingMessage];
    for (TSAttachmentPointer *pointer in attachmentPointers) {
        [pointer anyInsertWithTransaction:transaction];
        [incomingMessage.attachmentIds addObject:pointer.uniqueId];
    }

    if (!incomingMessage.hasRenderableContent) {
        OWSLogWarn(@"Ignoring empty: %@", messageDescription);
        return nil;
    }

    [incomingMessage anyInsertWithTransaction:transaction];

    // Any messages sent from the current user - from this device or another - should be automatically marked as read.
    if ([envelope.source isEqualToString:self.tsAccountManager.localNumber]) {
        // Don't send a read receipt for messages sent by ourselves.
        [incomingMessage markAsReadAtTimestamp:envelope.timestamp
                               sendReadReceipt:NO
                                   transaction:transaction.transitional_yapWriteTransaction];
    }

    // Download the "non-message body" attachments.
    NSMutableArray<NSString *> *otherAttachmentIds = [incomingMessage.allAttachmentIds mutableCopy];
    if (incomingMessage.attachmentIds) {
        [otherAttachmentIds removeObjectsInArray:incomingMessage.attachmentIds];
    }
    for (NSString *attachmentId in otherAttachmentIds) {
        TSAttachment *_Nullable attachment = [TSAttachment anyFetchWithUniqueId:attachmentId transaction:transaction];
        if (![attachment isKindOfClass:[TSAttachmentPointer class]]) {
            OWSLogInfo(@"Skipping attachment stream.");
            continue;
        }
        TSAttachmentPointer *_Nullable attachmentPointer = (TSAttachmentPointer *)attachment;

        OWSLogDebug(@"Downloading attachment for message: %lu", (unsigned long)incomingMessage.timestamp);

        // Use a separate download for each attachment so that:
        //
        // * We update the message as each comes in.
        // * Failures don't interfere with successes.
        [self.attachmentDownloads downloadAttachmentPointer:attachmentPointer
            message:incomingMessage
            success:^(NSArray<TSAttachmentStream *> *attachmentStreams) {
                [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
                    TSAttachmentStream *_Nullable attachmentStream = attachmentStreams.firstObject;
                    OWSAssertDebug(attachmentStream);
                    if (attachmentStream && incomingMessage.quotedMessage.thumbnailAttachmentPointerId.length > 0 &&
                        [attachmentStream.uniqueId
                            isEqualToString:incomingMessage.quotedMessage.thumbnailAttachmentPointerId]) {
                        [incomingMessage
                            anyUpdateWithTransaction:transaction
                                               block:^(TSInteraction *interaction) {
                                                   TSMessage *message = (TSMessage *)interaction;
                                                   [message setQuotedMessageThumbnailAttachmentStream:attachmentStream];
                                               }];
                    } else {
                        // We touch the message to trigger redraw of any views displaying it,
                        // since the attachment might be a contact avatar, etc.
                        if (transaction.transitional_yapWriteTransaction) {
                            [incomingMessage touchWithTransaction:transaction.transitional_yapWriteTransaction];
                        } else {
                            OWSFailDebug(@"GRDB TODO");
                        }
                    }
                }];
            }
            failure:^(NSError *error) {
                OWSLogWarn(@"failed to download attachment for message: %lu with error: %@",
                    (unsigned long)incomingMessage.timestamp,
                    error);
            }];
    }

    if (transaction.transitional_yapWriteTransaction) {
        // In case we already have a read receipt for this new message (this happens sometimes).
        [OWSReadReceiptManager.sharedManager
            applyEarlyReadReceiptsForIncomingMessage:incomingMessage
                                         transaction:transaction.transitional_yapWriteTransaction];

        // Update thread preview in inbox
        [thread touchWithTransaction:transaction.transitional_yapWriteTransaction];
    } else {
        OWSLogWarn(@"GRDB TODO");
    }

    [PerMessageExpiration applyEarlyReadReceiptsForIncomingMessage:incomingMessage transaction:transaction];

    [SSKEnvironment.shared.notificationsManager notifyUserForIncomingMessage:incomingMessage
                                                                    inThread:thread
                                                                 transaction:transaction];

    if (incomingMessage.messageSticker != nil) {
        [StickerManager.shared setHasUsedStickersWithTransaction:transaction];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.typingIndicators didReceiveIncomingMessageInThread:thread
                                                     recipientId:envelope.source
                                                        deviceId:envelope.sourceDevice];
    });

    return incomingMessage;
}

#pragma mark - helpers

- (BOOL)isDataMessageGroupAvatarUpdate:(SSKProtoDataMessage *)dataMessage
{
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return NO;
    }

    return (dataMessage.group != nil && dataMessage.group.hasType
        && dataMessage.group.unwrappedType == SSKProtoGroupContextTypeUpdate && dataMessage.group.avatar != nil);
}

/**
 * @returns
 *   Group or Contact thread for message, creating a new contact thread if necessary,
 *   but never creating a new group thread.
 */
- (nullable TSThread *)threadForEnvelope:(SSKProtoEnvelope *)envelope
                             dataMessage:(SSKProtoDataMessage *)dataMessage
                             transaction:(SDSAnyWriteTransaction *)transaction
{
    if (!envelope) {
        OWSFailDebug(@"Missing envelope.");
        return nil;
    }
    if (!dataMessage) {
        OWSFailDebug(@"Missing dataMessage.");
        return nil;
    }
    if (!transaction) {
        OWSFail(@"Missing transaction.");
        return nil;
    }

    if (dataMessage.group) {
        NSData *groupId = dataMessage.group.id;
        OWSAssertDebug(groupId.length > 0);
        TSGroupThread *_Nullable groupThread = [TSGroupThread threadWithGroupId:groupId anyTransaction:transaction];
        // This method should only be called from a code path that has already verified
        // that this is a "known" group.
        OWSAssertDebug(groupThread);
        return groupThread;
    } else {
        return [TSContactThread getOrCreateThreadWithContactId:envelope.source anyTransaction:transaction];
    }
}

#pragma mark -

- (void)checkForUnknownLinkedDevice:(SSKProtoEnvelope *)envelope transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(envelope);
    OWSAssertDebug(transaction);

    NSString *localNumber = self.tsAccountManager.localNumber;
    if (![localNumber isEqualToString:envelope.source]) {
        return;
    }

    // Consult the device list cache we use for message sending
    // whether or not we know about this linked device.
    SignalRecipient *_Nullable recipient =
        [SignalRecipient registeredRecipientForRecipientId:localNumber
                                           mustHaveDevices:NO
                                               transaction:transaction.transitional_yapWriteTransaction];
    if (!recipient) {
        OWSFailDebug(@"No local SignalRecipient.");
    } else {
        BOOL isRecipientDevice = [recipient.devices containsObject:@(envelope.sourceDevice)];
        if (!isRecipientDevice) {
            OWSLogInfo(@"Message received from unknown linked device; adding to local SignalRecipient: %lu.",
                       (unsigned long) envelope.sourceDevice);

            [recipient updateRegisteredRecipientWithDevicesToAdd:@[ @(envelope.sourceDevice) ]
                                                 devicesToRemove:nil
                                                     transaction:transaction.transitional_yapWriteTransaction];
        }
    }

    // Consult the device list cache we use for the "linked device" UI
    // whether or not we know about this linked device.
    NSMutableSet<NSNumber *> *deviceIdSet = [NSMutableSet new];
    for (OWSDevice *device in [OWSDevice currentDevicesWithTransaction:transaction.transitional_yapWriteTransaction]) {
        [deviceIdSet addObject:@(device.deviceId)];
    }
    BOOL isInDeviceList = [deviceIdSet containsObject:@(envelope.sourceDevice)];
    if (!isInDeviceList) {
        OWSLogInfo(@"Message received from unknown linked device; refreshing device list: %lu.",
                   (unsigned long) envelope.sourceDevice);

        [OWSDevicesService refreshDevices];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.profileManager fetchLocalUsersProfile];
        });
    }
}

@end

NS_ASSUME_NONNULL_END
