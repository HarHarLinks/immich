import { QueueName } from '@app/domain';
import { RegisterQueueOptions } from '@nestjs/bullmq';
import { QueueOptions } from 'bullmq';
import { RedisOptions } from 'ioredis';

function parseRedisConfig(): RedisOptions {
  if (process.env.IMMICH_TEST_ENV == 'true') {
    // Currently running e2e tests, do not use redis
    return {};
  }

  const redisUrl = process.env.REDIS_URL;
  if (redisUrl && redisUrl.startsWith('ioredis://')) {
    try {
      const decodedString = Buffer.from(redisUrl.slice(10), 'base64').toString();
      return JSON.parse(decodedString);
    } catch (error) {
      throw new Error(`Failed to decode redis options: ${error}`);
    }
  }
  return {
    host: process.env.REDIS_HOSTNAME || 'immich_redis',
    port: parseInt(process.env.REDIS_PORT || '6379'),
    db: parseInt(process.env.REDIS_DBINDEX || '0'),
    username: process.env.REDIS_USERNAME || undefined,
    password: process.env.REDIS_PASSWORD || undefined,
    path: process.env.REDIS_SOCKET || undefined,
  };
}

export const redisConfig: RedisOptions = parseRedisConfig();

export const bullConfig: QueueOptions = {
  prefix: 'immich_bull',
  connection: redisConfig,
  defaultJobOptions: {
    attempts: 3,
    removeOnComplete: true,
    removeOnFail: false,
  },
};

export const bullQueues: RegisterQueueOptions[] = Object.values(QueueName).map((name) => ({ name }));
