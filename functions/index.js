const {setGlobalOptions} = require("firebase-functions");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

initializeApp();

const db = getFirestore();

setGlobalOptions({
  maxInstances: 10,
  region: "asia-south1",
});

/*
 * ============================================================
 * COMPLETE RIDE
 * ============================================================
 *
 * Flutter app ride complete hone ke baad ye function call karega.
 *
 * Important:
 * Wallet / totalEarnings / totalKm ka final update
 * client ke instead trusted Firebase server karega.
 */
exports.completeRide = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError(
        "unauthenticated",
        "You must be logged in.",
    );
  }

  const uid = request.auth.uid;
  const data = request.data || {};

  const distanceKm = Number(data.distanceKm);
  const ratePerKm = Number(data.ratePerKm);
  const vehicleType = String(data.vehicleType || "Unknown");
  const startTime = data.startTime ?
    String(data.startTime) :
    new Date().toISOString();

  if (!Number.isFinite(distanceKm) || distanceKm < 0) {
    throw new HttpsError(
        "invalid-argument",
        "Invalid distance.",
    );
  }

  if (!Number.isFinite(ratePerKm) || ratePerKm < 0) {
    throw new HttpsError(
        "invalid-argument",
        "Invalid rate.",
    );
  }

  if (distanceKm > 1000) {
    throw new HttpsError(
        "invalid-argument",
        "Distance is too large.",
    );
  }

  if (ratePerKm > 10000) {
    throw new HttpsError(
        "invalid-argument",
        "Invalid rate.",
    );
  }

  const earning = Number(
      (distanceKm * ratePerKm).toFixed(2),
  );

  const userRef = db.collection("users").doc(uid);
  const rideRef = userRef.collection("rides").doc();

  await db.runTransaction(async (transaction) => {
    const userSnap = await transaction.get(userRef);

    if (!userSnap.exists) {
      throw new HttpsError(
          "not-found",
          "User account not found.",
      );
    }

    transaction.set(rideRef, {
      rideId: rideRef.id,
      userId: uid,
      distanceKm,
      ratePerKm,
      earning,
      vehicleType,
      startTime,
      endTime: new Date().toISOString(),
      createdAt: FieldValue.serverTimestamp(),
      status: "completed",
    });

    transaction.update(userRef, {
      totalKm: FieldValue.increment(distanceKm),
      totalEarnings: FieldValue.increment(earning),
      walletBalance: FieldValue.increment(earning),
    });
  });

  return {
    success: true,
    rideId: rideRef.id,
    distanceKm,
    earning,
  };
});


/*
 * ============================================================
 * COMPLETE REWARDED AD
 * ============================================================
 *
 * Flutter client ad complete hone ke baad ye function call karega.
 *
 * Server:
 * 1. User authenticate karta hai
 * 2. Ad document check karta hai
 * 3. Pending status check karta hai
 * 4. Duplicate reward rokta hai
 * 5. Wallet update karta hai
 * 6. Ad ko completed karta hai
 */
exports.completeRewardedAd = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError(
        "unauthenticated",
        "You must be logged in.",
    );
  }

  const uid = request.auth.uid;
  const data = request.data || {};

  const dayKey = String(data.dayKey || "");
  const adId = String(data.adId || "");

  if (!dayKey || !adId) {
    throw new HttpsError(
        "invalid-argument",
        "dayKey and adId are required.",
    );
  }

  if (!/^\d{4}-\d{2}-\d{2}$/.test(dayKey)) {
    throw new HttpsError(
        "invalid-argument",
        "Invalid date.",
    );
  }

  if (adId.length > 100) {
    throw new HttpsError(
        "invalid-argument",
        "Invalid ad ID.",
    );
  }

  const userRef = db.collection("users").doc(uid);

  const dayRef = userRef
      .collection("adDays")
      .doc(dayKey);

  const adRef = dayRef
      .collection("ads")
      .doc(adId);

  let rewardAmount = 0;

  await db.runTransaction(async (transaction) => {
    const [userSnap, daySnap, adSnap] =
      await Promise.all([
        transaction.get(userRef),
        transaction.get(dayRef),
        transaction.get(adRef),
      ]);

    if (!userSnap.exists) {
      throw new HttpsError(
          "not-found",
          "User account not found.",
      );
    }

    if (!daySnap.exists) {
      throw new HttpsError(
          "not-found",
          "Ad day not found.",
      );
    }

    if (!adSnap.exists) {
      throw new HttpsError(
          "not-found",
          "Advertisement not found.",
      );
    }

    const ad = adSnap.data();

    if (ad.status !== "pending") {
      throw new HttpsError(
          "already-exists",
          "This advertisement has already been completed.",
      );
    }

    const reward = Number(ad.reward);

    if (!Number.isFinite(reward) || reward <= 0 || reward > 1000) {
      throw new HttpsError(
          "failed-precondition",
          "Invalid reward amount.",
      );
    }

    rewardAmount = Number(reward.toFixed(2));

    const day = daySnap.data();

    const pendingAds = Math.max(
        0,
        Number(day.pendingAds || 0) - 1,
    );

    const completedAds =
      Number(day.completedAds || 0) + 1;

    const totalEarned =
      Number(day.totalEarned || 0) + rewardAmount;

    transaction.update(adRef, {
      status: "completed",
      completedAt: FieldValue.serverTimestamp(),
    });

    transaction.update(dayRef, {
      pendingAds,
      completedAds,
      totalEarned,
      updatedAt: FieldValue.serverTimestamp(),
    });

    transaction.update(userRef, {
      walletBalance: FieldValue.increment(rewardAmount),
      totalEarnings: FieldValue.increment(rewardAmount),
      adEarningsTotal: FieldValue.increment(rewardAmount),
    });
  });

  return {
    success: true,
    reward: rewardAmount,
    adId,
    dayKey,
  };
});
