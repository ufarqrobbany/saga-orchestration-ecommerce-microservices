#!/bin/bash

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Saga Orchestration Setup Script${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Create root directories
echo -e "${YELLOW}Creating directory structure...${NC}"

mkdir -p shared-library/src/types
mkdir -p shared-library/src/dto
mkdir -p shared-library/src/filters

mkdir -p api-gateway/src/{controllers,services,filters}
mkdir -p orchestrator-service/src/{orchestrator,services,controllers,entities}
mkdir -p order-service/src/{handlers,controllers,entities}
mkdir -p inventory-service/src/{handlers,controllers,entities}
mkdir -p payment-service/src/{handlers,controllers,entities}
mkdir -p shipping-service/src/{handlers,controllers,entities}

echo -e "${GREEN}✓ Directory structure created${NC}\n"

# Create shared library files
echo -e "${YELLOW}Creating shared library files...${NC}"

cat > shared-library/src/types/saga.types.ts << 'EOF'
export enum SagaState {
  INIT = 'INIT',
  ORDER_CREATED = 'ORDER_CREATED',
  STOCK_RESERVED = 'STOCK_RESERVED',
  PAYMENT_COMPLETED = 'PAYMENT_COMPLETED',
  SHIPPING_CREATED = 'SHIPPING_CREATED',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  COMPENSATING = 'COMPENSATING',
  UNKNOWN = 'UNKNOWN',
}

export enum CommandType {
  CREATE_ORDER = 'CREATE_ORDER',
  RESERVE_STOCK = 'RESERVE_STOCK',
  CHARGE_PAYMENT = 'CHARGE_PAYMENT',
  CREATE_SHIPMENT = 'CREATE_SHIPMENT',
  RELEASE_STOCK = 'RELEASE_STOCK',
  REFUND_PAYMENT = 'REFUND_PAYMENT',
  CANCEL_ORDER = 'CANCEL_ORDER',
}

export interface SagaCommand {
  saga_id: string;
  request_id: string;
  command_type: CommandType;
  timestamp: Date;
  payload: Record<string, any>;
  retry_count?: number;
}

export interface SagaResponse {
  saga_id: string;
  request_id: string;
  success: boolean;
  message: string;
  data?: Record<string, any>;
}

export interface SagaStateEntity {
  saga_id: string;
  order_id: string;
  current_state: SagaState;
  step_history: StepHistory[];
  retry_count: Record<string, number>;
  created_at: Date;
  updated_at: Date;
}

export interface StepHistory {
  step: string;
  state: SagaState;
  timestamp: Date;
  command_id: string;
}

export interface CircuitBreakerConfig {
  failure_threshold: number;
  success_threshold: number;
  timeout_ms: number;
  name: string;
}

export enum CircuitState {
  CLOSED = 'CLOSED',
  OPEN = 'OPEN',
  HALF_OPEN = 'HALF_OPEN',
}
EOF

cat > shared-library/src/dto/order.dto.ts << 'EOF'
export class CreateOrderRequest {
  user_id: string;
  items: OrderItem[];
  total_amount: number;
}

export class OrderItem {
  product_id: string;
  quantity: number;
  price: number;
}

export class OrderResponse {
  order_id: string;
  status: string;
  created_at: Date;
}
EOF

cat > shared-library/src/filters/http-exception.filter.ts << 'EOF'
import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  Logger,
} from '@nestjs/common';
import { Request, Response } from 'express';

@Catch(HttpException)
export class HttpExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(HttpExceptionFilter.name);

  catch(exception: HttpException, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request>();
    const status = exception.getStatus();
    const exceptionResponse = exception.getResponse();

    this.logger.error(
      `${request.method} ${request.url} - ${status} - ${JSON.stringify(
        exceptionResponse,
      )}`,
    );

    response.status(status).json({
      statusCode: status,
      timestamp: new Date().toISOString(),
      path: request.url,
      message:
        exceptionResponse['message'] || exception.getResponse(),
    });
  }
}
EOF

echo -e "${GREEN}✓ Shared library files created${NC}\n"

# Create API Gateway files
echo -e "${YELLOW}Creating API Gateway files...${NC}"

cat > api-gateway/src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { HttpExceptionFilter } from '../../../shared-library/src/filters/http-exception.filter';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  app.useGlobalFilters(new HttpExceptionFilter());
  app.enableCors();
  await app.listen(3000);
  console.log('🚀 API Gateway running on port 3000');
}

bootstrap();
EOF

cat > api-gateway/src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { HttpModule } from '@nestjs/axios';
import { OrderController } from './controllers/order.controller';
import { OrderService } from './services/order.service';

@Module({
  imports: [HttpModule],
  controllers: [OrderController],
  providers: [OrderService],
})
export class AppModule {}
EOF

cat > api-gateway/src/controllers/order.controller.ts << 'EOF'
import { Controller, Post, Body, Get, Param } from '@nestjs/common';
import { OrderService } from '../services/order.service';

@Controller('orders')
export class OrderController {
  constructor(private readonly orderService: OrderService) {}

  @Post('checkout')
  async checkout(@Body() request: any) {
    return this.orderService.startSaga(request);
  }

  @Get('saga/:saga_id')
  async getSagaStatus(@Param('saga_id') saga_id: string) {
    return this.orderService.getSagaStatus(saga_id);
  }
}
EOF

cat > api-gateway/src/services/order.service.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import { v4 as uuidv4 } from 'uuid';

@Injectable()
export class OrderService {
  private readonly logger = new Logger(OrderService.name);
  private orchestratorUrl = process.env.ORCHESTRATOR_URL || 'http://localhost:3001';

  constructor(private readonly httpService: HttpService) {}

  async startSaga(request: any) {
    const saga_id = uuidv4();

    try {
      this.logger.log(`Starting saga with ID: ${saga_id}`);
      const response = await firstValueFrom(
        this.httpService.post(
          `${this.orchestratorUrl}/saga/start`,
          {
            saga_id,
            order_request: request,
          },
          { timeout: 30000 },
        ),
      );
      return response.data;
    } catch (error) {
      this.logger.error(`Failed to start saga: ${error.message}`);
      throw new Error(`Failed to start saga: ${error.message}`);
    }
  }

  async getSagaStatus(saga_id: string) {
    try {
      this.logger.log(`Getting status for saga: ${saga_id}`);
      const response = await firstValueFrom(
        this.httpService.get(
          `${this.orchestratorUrl}/saga/${saga_id}/status`,
          { timeout: 10000 },
        ),
      );
      return response.data;
    } catch (error) {
      this.logger.error(`Failed to get saga status: ${error.message}`);
      throw new Error(`Failed to get saga status: ${error.message}`);
    }
  }
}
EOF

echo -e "${GREEN}✓ API Gateway files created${NC}\n"

# Create Orchestrator files
echo -e "${YELLOW}Creating Orchestrator Service files...${NC}"

cat > orchestrator-service/src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('saga');
  await app.listen(3001);
  console.log('🚀 Orchestrator Service running on port 3001');
}

bootstrap();
EOF

cat > orchestrator-service/src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { HttpModule } from '@nestjs/axios';
import { SagaOrchestrator } from './orchestrator/saga.orchestrator';
import { SagaController } from './controllers/saga.controller';
import { SagaEntity } from './entities/saga.entity';
import { CircuitBreakerService } from './services/circuit-breaker.service';
import { CommandDispatcher } from './services/command-dispatcher.service';

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.DB_PORT) || 5432,
      username: process.env.DB_USER || 'postgres',
      password: process.env.DB_PASSWORD || 'postgres',
      database: process.env.DB_NAME || 'orchestrator_db',
      entities: [SagaEntity],
      synchronize: true,
    }),
    TypeOrmModule.forFeature([SagaEntity]),
    HttpModule,
  ],
  controllers: [SagaController],
  providers: [SagaOrchestrator, CircuitBreakerService, CommandDispatcher],
})
export class AppModule {}
EOF

cat > orchestrator-service/src/entities/saga.entity.ts << 'EOF'
import { Entity, PrimaryColumn, Column, CreateDateColumn, UpdateDateColumn } from 'typeorm';

export enum SagaStateEnum {
  INIT = 'INIT',
  ORDER_CREATED = 'ORDER_CREATED',
  STOCK_RESERVED = 'STOCK_RESERVED',
  PAYMENT_COMPLETED = 'PAYMENT_COMPLETED',
  SHIPPING_CREATED = 'SHIPPING_CREATED',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  COMPENSATING = 'COMPENSATING',
}

@Entity('sagas')
export class SagaEntity {
  @PrimaryColumn('uuid')
  saga_id: string;

  @Column()
  order_id: string;

  @Column({
    type: 'enum',
    enum: SagaStateEnum,
    default: SagaStateEnum.INIT,
  })
  current_state: SagaStateEnum;

  @Column({ type: 'jsonb', default: [] })
  step_history: any[];

  @Column({ type: 'jsonb', default: {} })
  retry_count: Record<string, number>;

  @Column({ type: 'jsonb', nullable: true })
  order_data: Record<string, any>;

  @CreateDateColumn()
  created_at: Date;

  @UpdateDateColumn()
  updated_at: Date;
}
EOF

cat > orchestrator-service/src/services/circuit-breaker.service.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';

enum CircuitState {
  CLOSED = 'CLOSED',
  OPEN = 'OPEN',
  HALF_OPEN = 'HALF_OPEN',
}

interface CircuitBreakerState {
  state: CircuitState;
  failureCount: number;
  successCount: number;
  lastFailureTime: number;
  nextAttemptTime: number;
}

@Injectable()
export class CircuitBreakerService {
  private readonly logger = new Logger(CircuitBreakerService.name);
  private breakers = new Map<string, CircuitBreakerState>();

  private readonly config = {
    FAILURE_THRESHOLD: 5,
    SUCCESS_THRESHOLD: 2,
    TIMEOUT_MS: 60000,
    HALF_OPEN_ATTEMPTS: 1,
  };

  async executeWithFallback<T>(
    serviceName: string,
    action: () => Promise<T>,
    fallback?: () => Promise<T>,
  ): Promise<T> {
    const breaker = this.getOrCreateBreaker(serviceName);

    if (breaker.state === CircuitState.OPEN) {
      if (Date.now() < breaker.nextAttemptTime) {
        this.logger.warn(`⚠️ Circuit breaker OPEN for ${serviceName}`);
        if (fallback) {
          this.logger.log(`📍 Executing fallback for ${serviceName}`);
          return fallback();
        }
        throw new Error(`Circuit breaker OPEN for ${serviceName}`);
      }

      breaker.state = CircuitState.HALF_OPEN;
      this.logger.log(`🔄 Circuit breaker transitioning to HALF_OPEN for ${serviceName}`);
    }

    try {
      const result = await action();

      if (breaker.state === CircuitState.HALF_OPEN) {
        breaker.successCount++;
        if (breaker.successCount >= this.config.SUCCESS_THRESHOLD) {
          breaker.state = CircuitState.CLOSED;
          breaker.failureCount = 0;
          breaker.successCount = 0;
          this.logger.log(`✅ Circuit breaker CLOSED for ${serviceName}`);
        }
      } else if (breaker.state === CircuitState.CLOSED) {
        breaker.failureCount = Math.max(0, breaker.failureCount - 1);
      }

      return result;
    } catch (error) {
      breaker.failureCount++;
      breaker.lastFailureTime = Date.now();

      if (breaker.failureCount >= this.config.FAILURE_THRESHOLD) {
        breaker.state = CircuitState.OPEN;
        breaker.nextAttemptTime = Date.now() + this.config.TIMEOUT_MS;
        this.logger.error(
          `❌ Circuit breaker OPEN for ${serviceName} after ${breaker.failureCount} failures`,
        );
      }

      if (breaker.state === CircuitState.HALF_OPEN) {
        breaker.state = CircuitState.OPEN;
        breaker.nextAttemptTime = Date.now() + this.config.TIMEOUT_MS;
      }

      if (fallback) {
        this.logger.log(`📍 Executing fallback for ${serviceName}`);
        return fallback();
      }

      throw error;
    }
  }

  private getOrCreateBreaker(serviceName: string): CircuitBreakerState {
    if (!this.breakers.has(serviceName)) {
      this.breakers.set(serviceName, {
        state: CircuitState.CLOSED,
        failureCount: 0,
        successCount: 0,
        lastFailureTime: 0,
        nextAttemptTime: 0,
      });
    }
    return this.breakers.get(serviceName);
  }
}
EOF

cat > orchestrator-service/src/services/command-dispatcher.service.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';

enum CommandType {
  CREATE_ORDER = 'CREATE_ORDER',
  RESERVE_STOCK = 'RESERVE_STOCK',
  CHARGE_PAYMENT = 'CHARGE_PAYMENT',
  CREATE_SHIPMENT = 'CREATE_SHIPMENT',
  RELEASE_STOCK = 'RELEASE_STOCK',
  REFUND_PAYMENT = 'REFUND_PAYMENT',
  CANCEL_ORDER = 'CANCEL_ORDER',
}

@Injectable()
export class CommandDispatcher {
  private readonly logger = new Logger(CommandDispatcher.name);

  private readonly serviceMap = {
    [CommandType.CREATE_ORDER]: 'http://localhost:3002',
    [CommandType.RESERVE_STOCK]: 'http://localhost:3003',
    [CommandType.RELEASE_STOCK]: 'http://localhost:3003',
    [CommandType.CHARGE_PAYMENT]: 'http://localhost:3004',
    [CommandType.REFUND_PAYMENT]: 'http://localhost:3004',
    [CommandType.CREATE_SHIPMENT]: 'http://localhost:3005',
    [CommandType.CANCEL_ORDER]: 'http://localhost:3002',
  };

  constructor(private readonly httpService: HttpService) {}

  async dispatch(command: any) {
    const serviceUrl = this.serviceMap[command.command_type];

    if (!serviceUrl) {
      throw new Error(`No service mapping for command: ${command.command_type}`);
    }

    try {
      this.logger.log(
        `📤 Dispatching command: ${command.command_type} to ${serviceUrl}`,
      );

      const response = await firstValueFrom(
        this.httpService.post(`${serviceUrl}/command`, command, {
          timeout: 10000,
        }),
      );

      return response.data;
    } catch (error) {
      this.logger.error(
        `❌ Failed to dispatch command: ${command.command_type} - ${error.message}`,
      );
      throw error;
    }
  }
}
EOF

cat > orchestrator-service/src/orchestrator/saga.orchestrator.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { SagaEntity, SagaStateEnum } from '../entities/saga.entity';
import { CommandDispatcher } from '../services/command-dispatcher.service';
import { CircuitBreakerService } from '../services/circuit-breaker.service';
import { v4 as uuidv4 } from 'uuid';

enum CommandType {
  CREATE_ORDER = 'CREATE_ORDER',
  RESERVE_STOCK = 'RESERVE_STOCK',
  CHARGE_PAYMENT = 'CHARGE_PAYMENT',
  CREATE_SHIPMENT = 'CREATE_SHIPMENT',
  RELEASE_STOCK = 'RELEASE_STOCK',
  REFUND_PAYMENT = 'REFUND_PAYMENT',
  CANCEL_ORDER = 'CANCEL_ORDER',
}

@Injectable()
export class SagaOrchestrator {
  private readonly logger = new Logger(SagaOrchestrator.name);

  constructor(
    @InjectRepository(SagaEntity)
    private readonly sagaRepository: Repository<SagaEntity>,
    private readonly commandDispatcher: CommandDispatcher,
    private readonly circuitBreaker: CircuitBreakerService,
  ) {}

  async startSaga(saga_id: string, order_request: any) {
    this.logger.log(`🚀 Starting saga: ${saga_id}`);

    const saga = new SagaEntity();
    saga.saga_id = saga_id;
    saga.order_id = uuidv4();
    saga.current_state = SagaStateEnum.INIT;
    saga.step_history = [];
    saga.retry_count = {};
    saga.order_data = order_request;

    await this.sagaRepository.save(saga);

    try {
      await this.executeStep(saga_id, CommandType.CREATE_ORDER, order_request);
    } catch (error) {
      this.logger.error(`❌ Saga failed: ${error.message}`);
      await this.compensate(saga_id);
    }

    return { saga_id, status: 'started' };
  }

  async executeStep(saga_id: string, commandType: CommandType, payload: any) {
    const saga = await this.sagaRepository.findOne({ where: { saga_id } });
    if (!saga) {
      throw new Error(`Saga not found: ${saga_id}`);
    }

    const command = {
      saga_id,
      request_id: uuidv4(),
      command_type: commandType,
      timestamp: new Date(),
      payload,
      retry_count: 0,
    };

    try {
      const response = await this.dispatchCommandWithRetry(command, saga);

      if (!response.success) {
        this.logger.error(`❌ Command failed: ${commandType}`);
        throw new Error(`Command failed: ${response.message}`);
      }

      await this.recordStep(saga_id, commandType);
      await this.executeNextStep(saga_id, commandType, response.data);
    } catch (error) {
      this.logger.error(`❌ Step execution failed: ${error.message}`);
      throw error;
    }
  }

  private async dispatchCommandWithRetry(
    command: any,
    saga: SagaEntity,
    maxRetries = 3,
  ) {
    const maxRetryCount = saga.retry_count[command.command_type] || 0;

    if (maxRetryCount >= maxRetries) {
      throw new Error(`Max retries exceeded for ${command.command_type}`);
    }

    try {
      const response = await this.circuitBreaker.executeWithFallback(
        command.command_type,
        () => this.commandDispatcher.dispatch(command),
      );
      return response;
    } catch (error) {
      this.logger.warn(
        `⚠️ Retry attempt ${maxRetryCount + 1} for ${command.command_type}`,
      );
      saga.retry_count[command.command_type] = maxRetryCount + 1;
      await this.sagaRepository.save(saga);

      const delay = Math.pow(2, maxRetryCount) * 1000;
      await new Promise((resolve) => setTimeout(resolve, delay));

      return this.dispatchCommandWithRetry(command, saga, maxRetries);
    }
  }

  private async executeNextStep(
    saga_id: string,
    currentStep: CommandType,
    responseData: any,
  ) {
    const nextStep = this.getNextStep(currentStep);

    if (nextStep) {
      await this.executeStep(saga_id, nextStep, responseData);
    } else {
      await this.completeSaga(saga_id);
    }
  }

  private getNextStep(currentStep: CommandType): CommandType | null {
    const stepSequence = [
      CommandType.CREATE_ORDER,
      CommandType.RESERVE_STOCK,
      CommandType.CHARGE_PAYMENT,
      CommandType.CREATE_SHIPMENT,
    ];

    const currentIndex = stepSequence.indexOf(currentStep);
    return stepSequence[currentIndex + 1] || null;
  }

  async compensate(saga_id: string) {
    this.logger.log(`↩️ Starting compensation for saga: ${saga_id}`);

    const saga = await this.sagaRepository.findOne({ where: { saga_id } });
    if (!saga) {
      throw new Error(`Saga not found: ${saga_id}`);
    }

    saga.current_state = SagaStateEnum.COMPENSATING;
    await this.sagaRepository.save(saga);

    const compensationMap = {
      [SagaStateEnum.STOCK_RESERVED]: [CommandType.CANCEL_ORDER],
      [SagaStateEnum.PAYMENT_COMPLETED]: [
        CommandType.REFUND_PAYMENT,
        CommandType.RELEASE_STOCK,
        CommandType.CANCEL_ORDER,
      ],
      [SagaStateEnum.SHIPPING_CREATED]: [
        CommandType.REFUND_PAYMENT,
        CommandType.RELEASE_STOCK,
        CommandType.CANCEL_ORDER,
      ],
    };

    const compensationSteps = compensationMap[saga.current_state] || [];

    for (const compensationStep of compensationSteps) {
      try {
        const command = {
          saga_id,
          request_id: uuidv4(),
          command_type: compensationStep,
          timestamp: new Date(),
          payload: saga.order_data,
        };

        await this.commandDispatcher.dispatch(command);
        this.logger.log(`✅ Compensation step completed: ${compensationStep}`);
      } catch (error) {
        this.logger.error(
          `❌ Compensation step failed: ${compensationStep} - ${error.message}`,
        );
      }
    }

    saga.current_state = SagaStateEnum.FAILED;
    await this.sagaRepository.save(saga);
  }

  private async recordStep(saga_id: string, step: CommandType) {
    const saga = await this.sagaRepository.findOne({ where: { saga_id } });
    const stateMap = {
      [CommandType.CREATE_ORDER]: SagaStateEnum.ORDER_CREATED,
      [CommandType.RESERVE_STOCK]: SagaStateEnum.STOCK_RESERVED,
      [CommandType.CHARGE_PAYMENT]: SagaStateEnum.PAYMENT_COMPLETED,
      [CommandType.CREATE_SHIPMENT]: SagaStateEnum.SHIPPING_CREATED,
    };

    saga.step_history.push({
      step,
      state: stateMap[step],
      timestamp: new Date(),
      command_id: uuidv4(),
    });
    saga.current_state = stateMap[step];
    await this.sagaRepository.save(saga);
  }

  private async completeSaga(saga_id: string) {
    this.logger.log(`✅ Saga completed: ${saga_id}`);
    const saga = await this.sagaRepository.findOne({ where: { saga_id } });
    saga.current_state = SagaStateEnum.COMPLETED;
    await this.sagaRepository.save(saga);
  }

  async getSagaStatus(saga_id: string) {
    const saga = await this.sagaRepository.findOne({ where: { saga_id } });
    return saga;
  }
}
EOF

cat > orchestrator-service/src/controllers/saga.controller.ts << 'EOF'
import { Controller, Post, Get, Body, Param } from '@nestjs/common';
import { SagaOrchestrator } from '../orchestrator/saga.orchestrator';

@Controller()
export class SagaController {
  constructor(private readonly sagaOrchestrator: SagaOrchestrator) {}

  @Post('start')
  async startSaga(@Body() body: { saga_id: string; order_request: any }) {
    return this.sagaOrchestrator.startSaga(body.saga_id, body.order_request);
  }

  @Get(':saga_id/status')
  async getSagaStatus(@Param('saga_id') saga_id: string) {
    return this.sagaOrchestrator.getSagaStatus(saga_id);
  }
}
EOF

echo -e "${GREEN}✓ Orchestrator Service files created${NC}\n"

# Create Order Service
echo -e "${YELLOW}Creating Order Service files...${NC}"

cat > order-service/src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  await app.listen(3002);
  console.log('🚀 Order Service running on port 3002');
}

bootstrap();
EOF

cat > order-service/src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OrderEntity } from './entities/order.entity';
import { OrderCommandHandler } from './handlers/order-command.handler';
import { OrderController } from './controllers/order.controller';

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.DB_PORT) || 5432,
      username: process.env.DB_USER || 'postgres',
      password: process.env.DB_PASSWORD || 'postgres',
      database: process.env.ORDER_DB_NAME || 'order_db',
      entities: [OrderEntity],
      synchronize: true,
    }),
    TypeOrmModule.forFeature([OrderEntity]),
  ],
  controllers: [OrderController],
  providers: [OrderCommandHandler],
})
export class AppModule {}
EOF

cat > order-service/src/entities/order.entity.ts << 'EOF'
import { Entity, PrimaryColumn, Column, CreateDateColumn, UpdateDateColumn } from 'typeorm';

export enum OrderStatus {
  PENDING = 'PENDING',
  CONFIRMED = 'CONFIRMED',
  CANCELLED = 'CANCELLED',
}

@Entity('orders')
export class OrderEntity {
  @PrimaryColumn('uuid')
  order_id: string;

  @Column('uuid')
  saga_id: string;

  @Column('uuid')
  user_id: string;

  @Column({ type: 'enum', enum: OrderStatus, default: OrderStatus.PENDING })
  status: OrderStatus;

  @Column({ type: 'decimal', precision: 10, scale: 2 })
  total_amount: number;

  @Column({ type: 'jsonb' })
  items: Record<string, any>;

  @CreateDateColumn()
  created_at: Date;

  @UpdateDateColumn()
  updated_at: Date;
}
EOF

cat > order-service/src/handlers/order-command.handler.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { OrderEntity, OrderStatus } from '../entities/order.entity';
import { v4 as uuidv4 } from 'uuid';

enum CommandType {
  CREATE_ORDER = 'CREATE_ORDER',
  CANCEL_ORDER = 'CANCEL_ORDER',
}

@Injectable()
export class OrderCommandHandler {
  private readonly logger = new Logger(OrderCommandHandler.name);

  constructor(
    @InjectRepository(OrderEntity)
    private readonly orderRepository: Repository<OrderEntity>,
  ) {}

  async handle(command: any) {
    this.logger.log(`📥 Handling command: ${command.command_type}`);

    try {
      switch (command.command_type) {
        case CommandType.CREATE_ORDER:
          return await this.createOrder(command);
        case CommandType.CANCEL_ORDER:
          return await this.cancelOrder(command);
        default:
          throw new Error(`Unknown command: ${command.command_type}`);
      }
    } catch (error) {
      this.logger.error(`❌ Command failed: ${error.message}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: error.message,
      };
    }
  }

  private async createOrder(command: any) {
    const order = new OrderEntity();
    order.order_id = uuidv4();
    order.saga_id = command.saga_id;
    order.user_id = command.payload.user_id;
    order.total_amount = command.payload.total_amount;
    order.items = command.payload.items;
    order.status = OrderStatus.PENDING;

    const savedOrder = await this.orderRepository.save(order);

    this.logger.log(`✅ Order created: ${savedOrder.order_id}`);

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Order created successfully',
      data: {
        order_id: savedOrder.order_id,
        status: savedOrder.status,
      },
    };
  }

  private async cancelOrder(command: any) {
    const order = await this.orderRepository.findOne({
      where: { saga_id: command.saga_id },
    });

    if (!order) {
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: 'Order not found',
      };
    }

    order.status = OrderStatus.CANCELLED;
    await this.orderRepository.save(order);

    this.logger.log(`✅ Order cancelled: ${order.order_id}`);

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Order cancelled successfully',
      data: { order_id: order.order_id },
    };
  }
}
EOF

cat > order-service/src/controllers/order.controller.ts << 'EOF'
import { Controller, Post, Body } from '@nestjs/common';
import { OrderCommandHandler } from '../handlers/order-command.handler';

@Controller('command')
export class OrderController {
  constructor(private readonly commandHandler: OrderCommandHandler) {}

  @Post()
  async handleCommand(@Body() command: any) {
    return this.commandHandler.handle(command);
  }
}
EOF

echo -e "${GREEN}✓ Order Service files created${NC}\n"

# Create Inventory Service
echo -e "${YELLOW}Creating Inventory Service files...${NC}"

cat > inventory-service/src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  await app.listen(3003);
  console.log('🚀 Inventory Service running on port 3003');
}

bootstrap();
EOF

cat > inventory-service/src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { InventoryEntity } from './entities/inventory.entity';
import { ReservationEntity } from './entities/reservation.entity';
import { InventoryCommandHandler } from './handlers/inventory-command.handler';
import { InventoryController } from './controllers/inventory.controller';

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.DB_PORT) || 5432,
      username: process.env.DB_USER || 'postgres',
      password: process.env.DB_PASSWORD || 'postgres',
      database: process.env.INVENTORY_DB_NAME || 'inventory_db',
      entities: [InventoryEntity, ReservationEntity],
      synchronize: true,
    }),
    TypeOrmModule.forFeature([InventoryEntity, ReservationEntity]),
  ],
  controllers: [InventoryController],
  providers: [InventoryCommandHandler],
})
export class AppModule {}
EOF

cat > inventory-service/src/entities/inventory.entity.ts << 'EOF'
import { Entity, PrimaryColumn, Column, CreateDateColumn, UpdateDateColumn } from 'typeorm';

@Entity('inventory')
export class InventoryEntity {
  @PrimaryColumn('uuid')
  product_id: string;

  @Column()
  product_name: string;

  @Column()
  quantity: number;

  @Column()
  reserved_quantity: number;

  @CreateDateColumn()
  created_at: Date;

  @UpdateDateColumn()
  updated_at: Date;
}
EOF

cat > inventory-service/src/entities/reservation.entity.ts << 'EOF'
import { Entity, PrimaryColumn, Column, CreateDateColumn } from 'typeorm';

@Entity('reservations')
export class ReservationEntity {
  @PrimaryColumn('uuid')
  reservation_id: string;

  @Column('uuid')
  saga_id: string;

  @Column('uuid')
  product_id: string;

  @Column()
  quantity: number;

  @CreateDateColumn()
  created_at: Date;
}
EOF

cat > inventory-service/src/handlers/inventory-command.handler.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { InventoryEntity } from '../entities/inventory.entity';
import { ReservationEntity } from '../entities/reservation.entity';
import { v4 as uuidv4 } from 'uuid';

enum CommandType {
  RESERVE_STOCK = 'RESERVE_STOCK',
  RELEASE_STOCK = 'RELEASE_STOCK',
}

@Injectable()
export class InventoryCommandHandler {
  private readonly logger = new Logger(InventoryCommandHandler.name);

  constructor(
    @InjectRepository(InventoryEntity)
    private readonly inventoryRepository: Repository<InventoryEntity>,
    @InjectRepository(ReservationEntity)
    private readonly reservationRepository: Repository<ReservationEntity>,
  ) {}

  async handle(command: any) {
    this.logger.log(`📥 Handling command: ${command.command_type}`);

    try {
      switch (command.command_type) {
        case CommandType.RESERVE_STOCK:
          return await this.reserveStock(command);
        case CommandType.RELEASE_STOCK:
          return await this.releaseStock(command);
        default:
          throw new Error(`Unknown command: ${command.command_type}`);
      }
    } catch (error) {
      this.logger.error(`❌ Command failed: ${error.message}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: error.message,
      };
    }
  }

  private async reserveStock(command: any) {
    const items = command.payload.items || [];

    for (const item of items) {
      let inventory = await this.inventoryRepository.findOne({
        where: { product_id: item.product_id },
      });

      if (!inventory) {
        inventory = new InventoryEntity();
        inventory.product_id = item.product_id;
        inventory.product_name = `Product ${item.product_id}`;
        inventory.quantity = 1000;
        inventory.reserved_quantity = 0;
        await this.inventoryRepository.save(inventory);
      }

      const availableQuantity =
        inventory.quantity - inventory.reserved_quantity;

      if (availableQuantity < item.quantity) {
        return {
          saga_id: command.saga_id,
          request_id: command.request_id,
          success: false,
          message: `Insufficient stock for product: ${item.product_id}`,
        };
      }

      const reservation = new ReservationEntity();
      reservation.reservation_id = uuidv4();
      reservation.saga_id = command.saga_id;
      reservation.product_id = item.product_id;
      reservation.quantity = item.quantity;

      await this.reservationRepository.save(reservation);

      inventory.reserved_quantity += item.quantity;
      await this.inventoryRepository.save(inventory);

      this.logger.log(
        `✅ Stock reserved: ${item.product_id} - ${item.quantity} units`,
      );
    }

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Stock reserved successfully',
      data: { reserved_items: items },
    };
  }

  private async releaseStock(command: any) {
    const reservations = await this.reservationRepository.find({
      where: { saga_id: command.saga_id },
    });

    for (const reservation of reservations) {
      const inventory = await this.inventoryRepository.findOne({
        where: { product_id: reservation.product_id },
      });

      if (inventory) {
        inventory.reserved_quantity = Math.max(
          0,
          inventory.reserved_quantity - reservation.quantity,
        );
        await this.inventoryRepository.save(inventory);
      }

      await this.reservationRepository.remove(reservation);

      this.logger.log(
        `✅ Stock released: ${reservation.product_id} - ${reservation.quantity} units`,
      );
    }

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Stock released successfully',
    };
  }
}
EOF

cat > inventory-service/src/controllers/inventory.controller.ts << 'EOF'
import { Controller, Post, Body } from '@nestjs/common';
import { InventoryCommandHandler } from '../handlers/inventory-command.handler';

@Controller('command')
export class InventoryController {
  constructor(private readonly commandHandler: InventoryCommandHandler) {}

  @Post()
  async handleCommand(@Body() command: any) {
    return this.commandHandler.handle(command);
  }
}
EOF

echo -e "${GREEN}✓ Inventory Service files created${NC}\n"

# Create Payment Service
echo -e "${YELLOW}Creating Payment Service files...${NC}"

cat > payment-service/src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  await app.listen(3004);
  console.log('🚀 Payment Service running on port 3004');
}

bootstrap();
EOF

cat > payment-service/src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { PaymentEntity } from './entities/payment.entity';
import { PaymentCommandHandler } from './handlers/payment-command.handler';
import { PaymentController } from './controllers/payment.controller';

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.DB_PORT) || 5432,
      username: process.env.DB_USER || 'postgres',
      password: process.env.DB_PASSWORD || 'postgres',
      database: process.env.PAYMENT_DB_NAME || 'payment_db',
      entities: [PaymentEntity],
      synchronize: true,
    }),
    TypeOrmModule.forFeature([PaymentEntity]),
  ],
  controllers: [PaymentController],
  providers: [PaymentCommandHandler],
})
export class AppModule {}
EOF

cat > payment-service/src/entities/payment.entity.ts << 'EOF'
import { Entity, PrimaryColumn, Column, CreateDateColumn, UpdateDateColumn } from 'typeorm';

export enum PaymentStatus {
  PENDING = 'PENDING',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  REFUNDED = 'REFUNDED',
}

@Entity('payments')
export class PaymentEntity {
  @PrimaryColumn('uuid')
  payment_id: string;

  @Column('uuid')
  saga_id: string;

  @Column('uuid')
  order_id: string;

  @Column({ type: 'decimal', precision: 10, scale: 2 })
  amount: number;

  @Column({ type: 'enum', enum: PaymentStatus, default: PaymentStatus.PENDING })
  status: PaymentStatus;

  @Column({ nullable: true })
  transaction_id: string;

  @Column({ nullable: true })
  error_message: string;

  @CreateDateColumn()
  created_at: Date;

  @UpdateDateColumn()
  updated_at: Date;
}
EOF

cat > payment-service/src/handlers/payment-command.handler.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { PaymentEntity, PaymentStatus } from '../entities/payment.entity';
import { v4 as uuidv4 } from 'uuid';

enum CommandType {
  CHARGE_PAYMENT = 'CHARGE_PAYMENT',
  REFUND_PAYMENT = 'REFUND_PAYMENT',
}

@Injectable()
export class PaymentCommandHandler {
  private readonly logger = new Logger(PaymentCommandHandler.name);

  constructor(
    @InjectRepository(PaymentEntity)
    private readonly paymentRepository: Repository<PaymentEntity>,
  ) {}

  async handle(command: any) {
    this.logger.log(`📥 Handling command: ${command.command_type}`);

    try {
      switch (command.command_type) {
        case CommandType.CHARGE_PAYMENT:
          return await this.chargePayment(command);
        case CommandType.REFUND_PAYMENT:
          return await this.refundPayment(command);
        default:
          throw new Error(`Unknown command: ${command.command_type}`);
      }
    } catch (error) {
      this.logger.error(`❌ Command failed: ${error.message}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: error.message,
      };
    }
  }

  private async chargePayment(command: any) {
    const existingPayment = await this.paymentRepository.findOne({
      where: { saga_id: command.saga_id },
    });

    if (existingPayment && existingPayment.status === PaymentStatus.COMPLETED) {
      this.logger.log(`✅ Payment already processed for saga: ${command.saga_id}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: true,
        message: 'Payment already completed',
        data: { payment_id: existingPayment.payment_id },
      };
    }

    // Simulate payment processing (90% success rate)
    const success = Math.random() > 0.1;

    if (!success) {
      this.logger.error(`❌ Payment failed for saga: ${command.saga_id}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: 'Payment processing failed',
      };
    }

    const payment = new PaymentEntity();
    payment.payment_id = uuidv4();
    payment.saga_id = command.saga_id;
    payment.order_id = command.payload.order_id;
    payment.amount = command.payload.total_amount;
    payment.status = PaymentStatus.COMPLETED;
    payment.transaction_id = uuidv4();

    const savedPayment = await this.paymentRepository.save(payment);

    this.logger.log(`✅ Payment charged: ${savedPayment.payment_id}`);

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Payment charged successfully',
      data: {
        payment_id: savedPayment.payment_id,
        transaction_id: savedPayment.transaction_id,
      },
    };
  }

  private async refundPayment(command: any) {
    const payment = await this.paymentRepository.findOne({
      where: { saga_id: command.saga_id },
    });

    if (!payment) {
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: 'Payment not found',
      };
    }

    if (payment.status === PaymentStatus.REFUNDED) {
      this.logger.log(`✅ Payment already refunded for saga: ${command.saga_id}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: true,
        message: 'Payment already refunded',
      };
    }

    payment.status = PaymentStatus.REFUNDED;
    await this.paymentRepository.save(payment);

    this.logger.log(`✅ Payment refunded: ${payment.payment_id}`);

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Payment refunded successfully',
      data: { payment_id: payment.payment_id },
    };
  }
}
EOF

cat > payment-service/src/controllers/payment.controller.ts << 'EOF'
import { Controller, Post, Body } from '@nestjs/common';
import { PaymentCommandHandler } from '../handlers/payment-command.handler';

@Controller('command')
export class PaymentController {
  constructor(private readonly commandHandler: PaymentCommandHandler) {}

  @Post()
  async handleCommand(@Body() command: any) {
    return this.commandHandler.handle(command);
  }
}
EOF

echo -e "${GREEN}✓ Payment Service files created${NC}\n"

# Create Shipping Service
echo -e "${YELLOW}Creating Shipping Service files...${NC}"

cat > shipping-service/src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  await app.listen(3005);
  console.log('🚀 Shipping Service running on port 3005');
}

bootstrap();
EOF

cat > shipping-service/src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ShipmentEntity } from './entities/shipment.entity';
import { ShippingCommandHandler } from './handlers/shipping-command.handler';
import { ShippingController } from './controllers/shipping.controller';

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.DB_PORT) || 5432,
      username: process.env.DB_USER || 'postgres',
      password: process.env.DB_PASSWORD || 'postgres',
      database: process.env.SHIPPING_DB_NAME || 'shipping_db',
      entities: [ShipmentEntity],
      synchronize: true,
    }),
    TypeOrmModule.forFeature([ShipmentEntity]),
  ],
  controllers: [ShippingController],
  providers: [ShippingCommandHandler],
})
export class AppModule {}
EOF

cat > shipping-service/src/entities/shipment.entity.ts << 'EOF'
import { Entity, PrimaryColumn, Column, CreateDateColumn, UpdateDateColumn } from 'typeorm';

export enum ShipmentStatus {
  PENDING = 'PENDING',
  SHIPPED = 'SHIPPED',
  CANCELLED = 'CANCELLED',
}

@Entity('shipments')
export class ShipmentEntity {
  @PrimaryColumn('uuid')
  shipment_id: string;

  @Column('uuid')
  saga_id: string;

  @Column('uuid')
  order_id: string;

  @Column({ type: 'enum', enum: ShipmentStatus, default: ShipmentStatus.PENDING })
  status: ShipmentStatus;

  @Column({ nullable: true })
  tracking_number: string;

  @Column({ nullable: true })
  error_message: string;

  @CreateDateColumn()
  created_at: Date;

  @UpdateDateColumn()
  updated_at: Date;
}
EOF

cat > shipping-service/src/handlers/shipping-command.handler.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { ShipmentEntity, ShipmentStatus } from '../entities/shipment.entity';
import { v4 as uuidv4 } from 'uuid';

enum CommandType {
  CREATE_SHIPMENT = 'CREATE_SHIPMENT',
}

@Injectable()
export class ShippingCommandHandler {
  private readonly logger = new Logger(ShippingCommandHandler.name);

  constructor(
    @InjectRepository(ShipmentEntity)
    private readonly shipmentRepository: Repository<ShipmentEntity>,
  ) {}

  async handle(command: any) {
    this.logger.log(`📥 Handling command: ${command.command_type}`);

    try {
      switch (command.command_type) {
        case CommandType.CREATE_SHIPMENT:
          return await this.createShipment(command);
        default:
          throw new Error(`Unknown command: ${command.command_type}`);
      }
    } catch (error) {
      this.logger.error(`❌ Command failed: ${error.message}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: error.message,
      };
    }
  }

  private async createShipment(command: any) {
    const existingShipment = await this.shipmentRepository.findOne({
      where: { saga_id: command.saga_id },
    });

    if (existingShipment && existingShipment.status === ShipmentStatus.SHIPPED) {
      this.logger.log(`✅ Shipment already created for saga: ${command.saga_id}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: true,
        message: 'Shipment already created',
        data: { shipment_id: existingShipment.shipment_id },
      };
    }

    // Simulate shipping process (80% success rate)
    const success = Math.random() > 0.2;

    if (!success) {
      this.logger.error(`❌ Shipment creation failed for saga: ${command.saga_id}`);
      return {
        saga_id: command.saga_id,
        request_id: command.request_id,
        success: false,
        message: 'Shipment creation failed',
      };
    }

    const shipment = new ShipmentEntity();
    shipment.shipment_id = uuidv4();
    shipment.saga_id = command.saga_id;
    shipment.order_id = command.payload.order_id;
    shipment.status = ShipmentStatus.SHIPPED;
    shipment.tracking_number = `TRACK-${uuidv4().substring(0, 8)}`;

    const savedShipment = await this.shipmentRepository.save(shipment);

    this.logger.log(`✅ Shipment created: ${savedShipment.shipment_id}`);

    return {
      saga_id: command.saga_id,
      request_id: command.request_id,
      success: true,
      message: 'Shipment created successfully',
      data: {
        shipment_id: savedShipment.shipment_id,
        tracking_number: savedShipment.tracking_number,
      },
    };
  }
}
EOF

cat > shipping-service/src/controllers/shipping.controller.ts << 'EOF'
import { Controller, Post, Body } from '@nestjs/common';
import { ShippingCommandHandler } from '../handlers/shipping-command.handler';

@Controller('command')
export class ShippingController {
  constructor(private readonly commandHandler: ShippingCommandHandler) {}

  @Post()
  async handleCommand(@Body() command: any) {
    return this.commandHandler.handle(command);
  }
}
EOF

echo -e "${GREEN}✓ Shipping Service files created${NC}\n"

# Create configuration files
echo -e "${YELLOW}Creating configuration files...${NC}"

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.9'

services:
  postgres:
    image: postgres:15-alpine
    container_name: saga_postgres
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=en_US.UTF-8"
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - saga_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  api-gateway:
    build:
      context: ./api-gateway
      dockerfile: Dockerfile
    container_name: saga_api_gateway
    ports:
      - "3000:3000"
    environment:
      ORCHESTRATOR_URL: http://orchestrator-service:3001
    depends_on:
      - orchestrator-service
    networks:
      - saga_network

  orchestrator-service:
    build:
      context: ./orchestrator-service
      dockerfile: Dockerfile
    container_name: saga_orchestrator
    ports:
      - "3001:3001"
    environment:
      DB_HOST: postgres
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: postgres
      DB_NAME: orchestrator_db
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - saga_network

  order-service:
    build:
      context: ./order-service
      dockerfile: Dockerfile
    container_name: saga_order_service
    ports:
      - "3002:3002"
    environment:
      DB_HOST: postgres
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: postgres
      ORDER_DB_NAME: order_db
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - saga_network

  inventory-service:
    build:
      context: ./inventory-service
      dockerfile: Dockerfile
    container_name: saga_inventory_service
    ports:
      - "3003:3003"
    environment:
      DB_HOST: postgres
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: postgres
      INVENTORY_DB_NAME: inventory_db
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - saga_network

  payment-service:
    build:
      context: ./payment-service
      dockerfile: Dockerfile
    container_name: saga_payment_service
    ports:
      - "3004:3004"
    environment:
      DB_HOST: postgres
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: postgres
      PAYMENT_DB_NAME: payment_db
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - saga_network

  shipping-service:
    build:
      context: ./shipping-service
      dockerfile: Dockerfile
    container_name: saga_shipping_service
    ports:
      - "3005:3005"
    environment:
      DB_HOST: postgres
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: postgres
      SHIPPING_DB_NAME: shipping_db
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - saga_network

volumes:
  postgres_data:

networks:
  saga_network:
    driver: bridge
EOF

# Create .dockerignore
cat > api-gateway/.dockerignore << 'EOF'
node_modules
dist
.git
.env
.DS_Store
EOF

cat > orchestrator-service/.dockerignore << 'EOF'
node_modules
dist
.git
.env
.DS_Store
EOF

cat > order-service/.dockerignore << 'EOF'
node_modules
dist
.git
.env
.DS_Store
EOF

cat > inventory-service/.dockerignore << 'EOF'
node_modules
dist
.git
.env
.DS_Store
EOF

cat > payment-service/.dockerignore << 'EOF'
node_modules
dist
.git
.env
.DS_Store
EOF

cat > shipping-service/.dockerignore << 'EOF'
node_modules
dist
.git
.env
.DS_Store
EOF

# Create Dockerfiles for each service
for service in api-gateway orchestrator-service order-service inventory-service payment-service shipping-service; do
  cat > "$service/Dockerfile" << 'DOCKERFILE'
FROM node:18-alpine

WORKDIR /app

COPY package*.json ./

RUN npm ci --only=production

COPY dist ./dist

EXPOSE 3000

CMD ["node", "dist/main"]
DOCKERFILE
done

# Create tsconfig.json for each service
for service in api-gateway orchestrator-service order-service inventory-service payment-service shipping-service; do
  cat > "$service/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "module": "commonjs",
    "target": "ES2021",
    "lib": ["ES2021"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF
done

# Create .gitignore
cat > .gitignore << 'EOF'
node_modules
dist
.env
.env.local
.DS_Store
*.log
EOF

echo -e "${GREEN}✓ Configuration files created${NC}\n"

# Create main README
cat > README.md << 'EOFREADME'
# 🚀 Saga Orchestration E-Commerce Microservices

Complete implementation of **Saga Orchestration Pattern** for e-commerce checkout flow with **Circuit Breaker**, **Retry Logic**, and **Compensation Transactions**.

## 📊 Architecture

EOFREADME
