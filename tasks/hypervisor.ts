import { expect } from 'chai'
import { constants, Wallet } from 'ethers'
import { formatEther, parseEther} from 'ethers/lib/utils'
import { task } from 'hardhat/config'
import { deployContract, signPermission } from './utils'
import {
    FeeAmount,
    TICK_SPACINGS,
    encodePriceSqrt,
    getPositionKey,
    getMinTick,
    getMaxTick
} from './shared/utilities'

task('deploy-hypervisor-factory', 'Deploy Hypervisor contract')
  .setAction(async (cliArgs, { ethers, run, network }) => {

    const args = {
      uniswapFactory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
    };

    console.log('Network')
    console.log('  ', network.name)
    console.log('Task Args')
    console.log(args)

    // compile

    await run('compile')

    // get signer

    const signer = (await ethers.getSigners())[0]
    console.log('Signer')
    console.log('  at', signer.address)
    console.log('  ETH', formatEther(await signer.getBalance()))

    // deploy contracts

    const hypervisorFactoryFactory = await ethers.getContractFactory('HypervisorFactory')

    const hypervisorFactory = await deployContract(
      'HypervisorFactory',
      await ethers.getContractFactory('HypervisorFactory'),
      signer,
      [args.uniswapFactory]
    )

    await hypervisorFactory.deployTransaction.wait(5)
    await run('verify:verify', {
      address: hypervisorFactory.address,
      constructorArguments: [args.uniswapFactory],
    })
})

task('deploy-hypervisor-orphan', 'Deploy Hypervisor contract without factory')
  .addParam('pool', 'the uniswap pool address')
  .addParam('name', 'erc20 name')
  .addParam('symbol', 'erc2 symbol')
  .setAction(async (cliArgs, { ethers, run, network }) => {

    // compile

    await run('compile')

    // get signer

    const signer = (await ethers.getSigners())[0]
    console.log('Signer')
    console.log('  at', signer.address)
    console.log('  ETH', formatEther(await signer.getBalance()))

    const args = {
      pool: cliArgs.pool,
      owner: signer.address,
      name: cliArgs.name,
      symbol: cliArgs.symbol 
    }

    console.log('Network')
    console.log('  ', network.name)
    console.log('Task Args')
    console.log(args)

    const hypervisor = await deployContract(
      'Hypervisor',
      await ethers.getContractFactory('Hypervisor'),
      signer,
      [args.pool, args.owner, args.name, args.symbol]
    )

    await hypervisor.deployTransaction.wait(5)
    await run('verify:verify', {
      address: hypervisor.address,
      constructorArguments: [args.pool, args.owner, args.name, args.symbol],
    })

  }); 

task('deploy-hypervisor', 'Deploy Hypervisor contract via the factory')
  .addParam('factory', 'address of hypervisor factory')
  .addParam('token0', 'token0 of pair')
  .addParam('token1', 'token1 of pair')
  .addParam('fee', 'LOW, MEDIUM, or HIGH')
  .addParam('name', 'erc20 name')
  .addParam('symbol', 'erc2 symbol')
  .setAction(async (cliArgs, { ethers, run, network }) => {

    await run('compile')

    // get signer

    const signer = (await ethers.getSigners())[0]
    console.log('Signer')
    console.log('  at', signer.address)
    console.log('  ETH', formatEther(await signer.getBalance()))
    
    const args = {
      factory: cliArgs.factory,  
      token0: cliArgs.token0,
      token1: cliArgs.token1,
      fee: FeeAmount[cliArgs.fee],
      name: cliArgs.name,
      symbol: cliArgs.symbol 
    };

    console.log('Network')
    console.log('  ', network.name)
    console.log('Task Args')
    console.log(args)


    const hypervisorFactory = await ethers.getContractAt(
      'HypervisorFactory',
      args.factory,
      signer,
    )

    const hypervisor = await hypervisorFactory.createHypervisor(
      args.token0, args.token1, args.fee, args.name, args.symbol) 

  })

task('verify-hypervisor', 'Verify Hypervisor contract')
  .addParam('hypervisor', 'the hypervisor to verify')
  .addParam('pool', 'the uniswap pool address')
  .addParam('name', 'erc20 name')
  .addParam('symbol', 'erc2 symbol')
  .setAction(async (cliArgs, { ethers, run, network }) => {

    console.log('Network')
    console.log('  ', network.name)

    await run('compile')

    // get signer

    const signer = (await ethers.getSigners())[0]
    console.log('Signer')
    console.log('  at', signer.address)
    console.log('  ETH', formatEther(await signer.getBalance()))

    const args = {
      pool: cliArgs.pool,
      owner: signer.address,
      name: cliArgs.name,
      symbol: cliArgs.symbol 
    }

    console.log('Task Args')
    console.log(args)

    const hypervisor = await ethers.getContractAt(
      'Hypervisor',
      cliArgs.hypervisor,
      signer,
    )
    await run('verify:verify', {
      address: hypervisor.address,
      constructorArguments: Object.values(args),
    })

  });

  task('deploy-uniproxy', 'Deploy UniProxy contract')
  .setAction(async (cliArgs, { ethers, run, network }) => {

    await run('compile')

    // get signer

    const signer = (await ethers.getSigners())[0]
    console.log('Signer')
    console.log('  at', signer.address)
    console.log('  ETH', formatEther(await signer.getBalance()))

    console.log('Network')
    console.log('  ', network.name)

    const uniProxyFactory = await ethers.getContractFactory('UniProxy')

    const uniProxy = await deployContract(
      'UniProxy',
      uniProxyFactory,
      signer
    )

    await uniProxy.deployTransaction.wait(5)
    await run('verify:verify', {
      address: uniProxy.address
    })
  })

  task('verify-uniproxy', 'Verify UniProxy contract')
  .addParam('uniproxy', 'the UniProxy to verify')
  .setAction(async (cliArgs, { ethers, run, network }) => {

    await run('compile')

    // get signer

    const signer = (await ethers.getSigners())[0]
    console.log('Signer')
    console.log('  at', signer.address)
    console.log('  ETH', formatEther(await signer.getBalance()))

    console.log('Network')
    console.log('  ', network.name)

    const uniProxy = await ethers.getContractAt(
      'UniProxy',
      cliArgs.uniproxy,
      signer,
    )

    await run('verify:verify', {
      address: uniProxy.address
    })
  })
