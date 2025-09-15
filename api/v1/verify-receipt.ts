// api/v1/verify-receipt.ts
/**
 * Receipt Verification Endpoint
 * Validates in-app purchase receipts and updates user subscription status
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withAuth, AuthContext } from '../_lib/auth';
import { logger } from '../_lib/logger';

interface ReceiptVerificationRequest {
  receiptData: string;
  productId: string;
  transactionId: string;
  platform: 'ios' | 'android';
}

interface ReceiptVerificationResponse {
  success: boolean;
  message: string;
  subscription?: {
    productId: string;
    transactionId: string;
    platform: string;
    verifiedAt: string;
    expiresAt?: string;
  };
}

export default withAuth(async (req: VercelRequest, res: VercelResponse, auth: AuthContext): Promise<void> => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const { receiptData, productId, transactionId, platform }: ReceiptVerificationRequest = req.body;

    if (!receiptData || !productId || !transactionId || !platform) {
      res.status(400).json({
        error: 'Missing required fields: receiptData, productId, transactionId, platform'
      });
      return;
    }

    logger.info('Verifying receipt', {
      userId: auth.userId,
      productId,
      transactionId,
      platform
    });

    // Verify receipt with platform (simplified for now)
    const verificationResult = await verifyReceiptWithPlatform({
      receiptData,
      productId,
      transactionId,
      platform
    });

    if (!verificationResult.success) {
      logger.warn('Receipt verification failed', {
        userId: auth.userId,
        productId,
        transactionId,
        platform,
        reason: verificationResult.reason
      });

      res.status(400).json({
        success: false,
        message: verificationResult.reason || 'Receipt verification failed'
      });
      return;
    }

    // Update user's subscription status in your database
    await updateUserSubscription(auth.userId, {
      productId,
      transactionId,
      platform,
      verifiedAt: new Date().toISOString(),
      expiresAt: verificationResult.expiresAt
    });

    logger.info('Receipt verified and subscription updated', {
      userId: auth.userId,
      productId,
      transactionId,
      platform
    });

    const response: ReceiptVerificationResponse = {
      success: true,
      message: 'Receipt verified successfully',
      subscription: {
        productId,
        transactionId,
        platform,
        verifiedAt: new Date().toISOString(),
        expiresAt: verificationResult.expiresAt
      }
    };

    res.status(200).json(response);

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logger.error('Receipt verification error', { error: errorMessage });
    res.status(500).json({
      success: false,
      message: 'Internal server error during receipt verification'
    });
  }
});

async function verifyReceiptWithPlatform(params: {
  receiptData: string;
  productId: string;
  transactionId: string;
  platform: 'ios' | 'android';
}): Promise<{ success: boolean; reason?: string; expiresAt?: string }> {
  const { receiptData, productId, transactionId, platform } = params;

  try {
    // For now, implement basic validation
    // In production, you would:
    // - iOS: Validate with Apple's verification servers
    // - Android: Validate with Google Play Developer API

    if (platform === 'ios') {
      // iOS receipt validation would go here
      // For now, accept receipts that look valid
      if (receiptData.length < 100) {
        return { success: false, reason: 'Invalid iOS receipt data' };
      }
    } else if (platform === 'android') {
      // Android receipt validation would go here
      if (receiptData.length < 50) {
        return { success: false, reason: 'Invalid Android receipt data' };
      }
    } else {
      return { success: false, reason: 'Unsupported platform' };
    }

    // Check if transaction ID looks valid
    if (!transactionId || transactionId.length < 10) {
      return { success: false, reason: 'Invalid transaction ID' };
    }

    // For monthly subscription, set expiration to 30 days from now
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 30);

    return {
      success: true,
      expiresAt: expiresAt.toISOString()
    };

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logger.error('Platform verification error', { error: errorMessage });
    return { success: false, reason: 'Verification service error' };
  }
}

async function updateUserSubscription(userId: string, subscription: {
  productId: string;
  transactionId: string;
  platform: string;
  verifiedAt: string;
  expiresAt?: string;
}): Promise<void> {
  // Update in-memory subscription store (replace with database in production)
  const subscriptionStore = (global as any).subscriptionStore || {};
  (global as any).subscriptionStore = subscriptionStore;

  subscriptionStore[userId] = {
    active: true,
    expiresAt: subscription.expiresAt
  };

  logger.info('Updated user subscription in store', { userId, subscription });

  // TODO: Update user's subscription status in your database
  // This would typically update a database like:
  // await db.users.update(userId, {
  //   subscription: {
  //     ...subscription,
  //     status: 'active'
  //   }
  // });

  // For the trial guard to work, we need to mark this user as having premium access
  // This could be done via a database update or cache invalidation
}