import { Router } from 'express';
import { getServerTime } from '../db/index.js';

export const healthRouter = Router();

healthRouter.get('/', (_req, res) => {
  res.json({ status: 'ok', time: getServerTime() });
});
