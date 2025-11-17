/***************************** BEGIN LICENSE BLOCK ***************************

 Copyright (C) 2020 Botts Innovative Research, Inc. All Rights Reserved.
 ******************************* END LICENSE BLOCK ***************************/
package org.sensorhub.node.test;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import org.sensorhub.impl.SensorHub;
import org.slf4j.LoggerFactory;


public class TestSensorHub
{
    private TestSensorHub()
    {        
    }
    
    public static void main(String[] args) throws Exception
    {
        Logger logger = (Logger) LoggerFactory.getLogger(Logger.ROOT_LOGGER_NAME);
        logger.setLevel(Level.DEBUG);
        SensorHub.main(new String[] {"tools/sensorhub-test/src/main/resources/config.json", "storage"});
    }
}
