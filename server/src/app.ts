import express, { type Express } from 'express';
import cors from 'cors';
import { todosRouter } from './routes/todos.js';
import { healthRouter } from './routes/health.js';

export function createApp(): Express {
  const app = express();
  app.use(cors());
  app.use(express.json({ limit: '5mb' }));

  app.use('/api/todos', todosRouter);
  app.use('/health', healthRouter);

  app.get('/', (_req, res) => res.json({ name: 'woo-todo-server', version: '2.0.0' }));

  return app;
}
