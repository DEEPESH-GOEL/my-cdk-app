import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';

interface Ec2StackProps extends cdk.StackProps {
  instanceName: string;
  environment: string;
  ami: string;
  instanceType: string;
}

export class Ec2Stack extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props: Ec2StackProps) {
    super(scope, id, props);

    const { instanceName, environment, ami, instanceType } = props;

    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    new ec2.Instance(this, 'WebInstance', {
      vpc,
      machineImage: ec2.MachineImage.genericLinux({ [this.region]: ami }),
      instanceType: new ec2.InstanceType(instanceType),
      tags: {
        Name:        `${instanceName}-${environment}`,
        Environment: environment,
        ManagedBy:   'cdk',
      },
    });
  }
}
