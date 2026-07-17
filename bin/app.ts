#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { Ec2Stack } from '../lib/ec2-stack';
import { S3Stack } from '../lib/s3-stack';

const app = new cdk.App();

const env = {
  account: process.env.AWS_ACCOUNT_ID,
  region:  process.env.AWS_REGION || 'us-east-1',
};

const instanceName = app.node.tryGetContext('instanceName') || 'myapp';
const environment  = app.node.tryGetContext('environment')  || 'dev';
const ami          = app.node.tryGetContext('ami')          || 'ami-0c02fb55956c7d316';
const instanceType = app.node.tryGetContext('instanceType') || 't3.micro';

new Ec2Stack(app, 'Ec2Stack', { instanceName, environment, ami, instanceType, env });
new S3Stack(app, 'S3Stack',   { instanceName, environment, env });
