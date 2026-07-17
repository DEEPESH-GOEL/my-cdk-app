import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';

interface S3StackProps extends cdk.StackProps {
  instanceName: string;
  environment: string;
}

export class S3Stack extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props: S3StackProps) {
    super(scope, id, props);

    const { instanceName, environment } = props;

    new s3.Bucket(this, 'StorageBucket', {
      bucketName: `${instanceName}-${environment}-storage`,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      tags: {
        Name:        `${instanceName}-${environment}-storage`,
        Environment: environment,
        ManagedBy:   'cdk',
      },
    });
  }
}
