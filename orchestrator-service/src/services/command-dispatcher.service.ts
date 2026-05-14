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
