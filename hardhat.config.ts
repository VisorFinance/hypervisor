import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-etherscan'
import '@nomiclabs/hardhat-waffle'
import '@typechain/hardhat'
import "hardhat-watcher"
import './scripts/copy-uniswap-v3-artifacts.ts'
import './tasks/hypervisor'
import './tasks/swap'
import { parseUnits } from 'ethers/lib/utils'
import { HardhatUserConfig } from 'hardhat/types'
require('dotenv').config()
const mnemonic = process.env.DEV_MNEMONIC || ''
const archive_node = process.env.ETHEREUM_ARCHIVE_URL || ''

const config: HardhatUserConfig = {
  networks: {
      hardhat: {
        allowUnlimitedContractSize: false,
      },
      mainnet: {
        url: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_API_KEY}`,
          accounts: {
            mnemonic,
          },

      },
  },
  watcher: {
      compilation: {
          tasks: ["compile"],
      }
  },
  solidity: {
      compilers: [
        {
            version: '0.7.6',
            settings: {
                optimizer: {
                    enabled: true,
                    runs: 800,
                },
                metadata: {
                    // do not include the metadata hash, since this is machine dependent
                    // and we want all generated code to be deterministic
                    // https://docs.soliditylang.org/en/v0.7.6/metadata.html
                    bytecodeHash: 'none',
                },
            },
        },
        {
          version: '0.6.11'
        }
      ],

  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_APIKEY,
  },
  mocha: {
    timeout: 2000000
  }
}
export default config;
